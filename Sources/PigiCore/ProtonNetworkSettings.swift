import CoreFoundation
import Darwin
import Foundation

/// How Proton mail sync reaches the network. IMAP and web content are unchanged.
public enum ProtonProxyMode: String, CaseIterable, Identifiable, Sendable {
    case system, manual, direct

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .manual: "手动代理"
        case .direct: "直连"
        }
    }

    /// Absent or unrecognized values stay on the default, which is system.
    public static func resolved(_ raw: String?) -> ProtonProxyMode {
        guard let raw, let mode = ProtonProxyMode(rawValue: raw) else { return .system }
        return mode
    }
}

public struct ProtonWireProxy: Equatable, Sendable, Encodable {
    public let scheme: String
    public let host: String
    public let port: Int
}

public enum ProtonProxyResolution: Equatable, Sendable {
    case direct
    /// System PAC is not executed. The helper is configured direct and the
    /// settings page tells the user to switch to a manual proxy.
    case pacIgnored
    case proxy(scheme: String, host: String, port: Int)
    case invalid

    public var wire: ProtonWireProxy? {
        switch self {
        case .direct, .pacIgnored:
            return ProtonWireProxy(scheme: "direct", host: "", port: 0)
        case let .proxy(scheme, host, port):
            return ProtonWireProxy(scheme: scheme, host: host, port: port)
        case .invalid:
            return nil
        }
    }
}

public struct ProtonNetworkSelection: Equatable, Sendable {
    public let mode: ProtonProxyMode
    public let resolution: ProtonProxyResolution
    public var wire: ProtonWireProxy? { resolution.wire }
}

/// Manual or system proxy settings that cannot be represented as scheme/host/port.
/// The helper is not started, so it cannot silently connect without a proxy.
public struct ProtonProxyConfigurationError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public static func make(_ selection: ProtonNetworkSelection) -> ProtonProxyConfigurationError {
        switch selection.mode {
        case .manual:
            return ProtonProxyConfigurationError(message: "手动代理主机或端口无效，Proton 不会改为直连")
        case .system:
            return ProtonProxyConfigurationError(message: "系统代理无法使用，Proton 不会改为直连")
        case .direct:
            return ProtonProxyConfigurationError(message: "Proton 网络配置无效，不会改为直连")
        }
    }
}

public enum ProtonNetworkSettings {
    public static let modeKey = "protonProxyMode"
    public static let schemeKey = "protonProxyManualScheme"
    public static let hostKey = "protonProxyManualHost"
    public static let portKey = "protonProxyManualPort"
    /// Exceptions and proxy choice are evaluated for the Proton API host.
    public static let protonAPIURL = URL(string: "https://mail.proton.me/api")!

    public static func current(defaults: UserDefaults = .standard) -> ProtonNetworkSelection {
        selection(
            mode: ProtonProxyMode.resolved(defaults.string(forKey: modeKey)),
            manualScheme: defaults.string(forKey: schemeKey) ?? "http",
            manualHost: defaults.string(forKey: hostKey) ?? "",
            manualPort: (defaults.object(forKey: portKey) as? NSNumber)?.intValue ?? 0
        )
    }

    public static func selection(mode: ProtonProxyMode, manualScheme: String = "http", manualHost: String = "", manualPort: Int = 0, systemSettings: [String: Any]? = nil, target: URL = protonAPIURL) -> ProtonNetworkSelection {
        let resolution: ProtonProxyResolution
        switch mode {
        case .direct:
            resolution = .direct
        case .manual:
            let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if validEndpoint(scheme: manualScheme, host: host, port: manualPort) {
                resolution = .proxy(scheme: manualScheme, host: host, port: manualPort)
            } else {
                resolution = .invalid
            }
        case .system:
            let settings = systemSettings ?? ((CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:])
            resolution = interpretSystem(settings, target: target)
        }
        return ProtonNetworkSelection(mode: mode, resolution: resolution)
    }

    /// `settings` is a `CFNetworkCopySystemProxySettings` dictionary. PAC wins
    /// over any sibling proxy: v1 does not execute the script and does not use
    /// the other entries. Otherwise HTTPS CONNECT, then SOCKS5, then direct.
    public static func interpretSystem(_ settings: [String: Any], target: URL = protonAPIURL) -> ProtonProxyResolution {
        let proxies = CFNetworkCopyProxiesForURL(target as CFURL, settings as CFDictionary).takeRetainedValue() as? [[String: Any]] ?? []
        let typeKey = kCFProxyTypeKey as String
        if proxies.contains(where: { ($0[typeKey] as? String) == (kCFProxyTypeAutoConfigurationURL as String) }) {
            return .pacIgnored
        }
        if let https = firstProxy(proxies, type: kCFProxyTypeHTTPS as String, scheme: "http") {
            return https
        }
        if let socks = firstProxy(proxies, type: kCFProxyTypeSOCKS as String, scheme: "socks5") {
            return socks
        }
        return .direct
    }

    public static func validEndpoint(scheme: String, host: String, port: Int) -> Bool {
        guard scheme == "http" || scheme == "socks5", (1...65535).contains(port) else { return false }
        guard !host.isEmpty, host.count <= 253, host.utf8.count == host.count else { return false }
        if host.contains("@") || host.contains("/") || host.contains("\\") || host.contains("?") || host.contains("#") || host.contains(" ") {
            return false
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        if host.contains(":") { return false }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    private static func firstProxy(_ proxies: [[String: Any]], type: String, scheme: String) -> ProtonProxyResolution? {
        let typeKey = kCFProxyTypeKey as String
        guard let row = proxies.first(where: { ($0[typeKey] as? String) == type }) else { return nil }
        let host = ((row[kCFProxyHostNameKey as String] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (row[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue ?? 0
        guard validEndpoint(scheme: scheme, host: host, port: port) else { return .invalid }
        return .proxy(scheme: scheme, host: host, port: port)
    }
}

extension ProtonHelperError {
    /// Copy depends on the proxy mode. `kind` stays on the wire code, so a
    /// dead proxy remains a network failure and does not raise the keychain banner.
    public func protonSyncMessage(mode: ProtonProxyMode, resolution: ProtonProxyResolution) -> String {
        switch self {
        case .network:
            switch mode {
            case .direct:
                return "无法连接 Proton，请检查网络后重试"
            case .system:
                if case let .proxy(_, host, port) = resolution {
                    return "无法连接 Proton，请检查网络与系统代理（\(host):\(port)）后重试"
                }
                return "无法连接 Proton，请检查网络与系统代理后重试"
            case .manual:
                if case let .proxy(_, host, port) = resolution {
                    return "无法连接 Proton，请检查手动代理 \(host):\(port) 后重试"
                }
                return "无法连接 Proton，请检查手动代理后重试"
            }
        case .timeout:
            switch mode {
            case .manual:
                if case let .proxy(_, host, port) = resolution {
                    return "Proton 请求超时，请检查手动代理 \(host):\(port) 后重试"
                }
                return "Proton 请求超时，请稍后重试"
            case .system:
                if case .proxy = resolution {
                    return "Proton 请求超时，请检查系统代理后重试"
                }
                return "Proton 请求超时，请稍后重试"
            case .direct:
                return "Proton 请求超时，请稍后重试"
            }
        case .proxy:
            switch mode {
            case .manual:
                if case let .proxy(_, host, port) = resolution {
                    return "代理需要认证（\(host):\(port)）。Proton 不支持带密码的代理，也不会改为直连"
                }
                return "代理需要认证。Proton 不支持带密码的代理，也不会改为直连"
            case .direct:
                return "代理需要认证，请检查系统代理设置"
            case .system:
                return "代理需要认证，请检查系统代理设置。Proton 不支持带密码的代理，也不会改为直连"
            }
        default:
            return "Proton 操作失败（\(rawValue)）"
        }
    }
}
