import Foundation

@main
struct ProtonHelperRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        if !condition() { throw TestFailure(name: name) }
    }
    struct TestFailure: Error { let name: String }

    static func fault(_ code: ProtonHelperError, _ work: () async throws -> Void) async throws {
        do { try await work(); throw TestFailure(name: "expected \(code.rawValue)") }
        catch let actual as ProtonHelperError { try expect(actual == code, "got \(actual.rawValue), expected \(code.rawValue)") }
    }

    static func main() async throws {
        UserDefaults.standard.setVolatileDomain(["protonProxyMode": "direct"], forName: UserDefaults.argumentDomain)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let actual = ProtonHelperClient(executable: root.appendingPathComponent("pigi-proton-helper"))
        let info = try await actual.negotiate()
        try expect(info.protocol == 1 && info.maxFrameBytes == ProtonHelperClient.maxFrame, "hello")
        try await fault(.notAuthenticated) { _ = try await actual.list() }
        try await fault(.invalidParams) { try await actual.login(username: "", password: "") }
        try await fault(.notAuthenticated) { _ = try await actual.decrypt(id: "synthetic") }
        try await actual.logout()
        _ = try await actual.negotiate() // clean restart after logout
        try await actual.logout()

        // Fixtures contain synthetic data only and never access the network.
        func fixture(_ name: String, _ source: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys,json,time,os\n" + source).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        try await loginCases(root: root)

        let mismatch = try fixture("wrong-id", "r=json.loads(sys.stdin.readline())\nprint(json.dumps({'version':1,'id':999,'result':{}}),flush=True)\n")
        try await fault(.protocolViolation) { _ = try await ProtonHelperClient(executable: mismatch).negotiate() }

        let invalidVersion = try fixture("wrong-version", "r=json.loads(sys.stdin.readline())\nprint(json.dumps({'version':2,'id':r['id'],'error':{'code':'unsupported_version'}}),flush=True)\n")
        try await fault(.protocolViolation) { _ = try await ProtonHelperClient(executable: invalidVersion).negotiate() }

        let unknownError = try fixture("unknown-error", "r=json.loads(sys.stdin.readline())\nprint(json.dumps({'version':1,'id':r['id'],'error':{'code':'SENSITIVE-SENTINEL'}}),flush=True)\n")
        try await fault(.protocolViolation) { _ = try await ProtonHelperClient(executable: unknownError).negotiate() }

        let oversized = try fixture("oversized", "sys.stdin.readline()\ntry:\n sys.stdout.write('x'*(8*1024*1024+2));sys.stdout.flush()\nexcept BrokenPipeError: os._exit(0)\n")
        try await fault(.frameTooLarge) { _ = try await ProtonHelperClient(executable: oversized).negotiate() }

        let stall = try fixture("stall", "sys.stdin.readline()\ntime.sleep(30)\n")
        let began = Date()
        try await fault(.timeout) { _ = try await ProtonHelperClient(executable: stall, timeout: 0.2).negotiate() }
        try expect(Date().timeIntervalSince(began) < 3, "watchdog must bound the call")

        let crash = try fixture("crash", "sys.stdin.readline()\nsys.stderr.write('SENSITIVE-SENTINEL');sys.stderr.flush()\nos._exit(1)\n")
        try await fault(.transport) { _ = try await ProtonHelperClient(executable: crash).negotiate() }
        try await networkCases(root: root)
        print("Proton Swift regression: handshake, restart, faults, correlation, size, timeout and crash passed.")
    }

    static func networkCases(root: URL) async throws {
        try expect(ProtonProxyMode.resolved(nil) == .system && ProtonProxyMode.resolved("later") == .system, "default system")
        let https = ProtonNetworkSettings.interpretSystem([
            "HTTPSEnable": 1, "HTTPSProxy": "proxy.example", "HTTPSPort": 8443,
            "SOCKSEnable": 1, "SOCKSProxy": "socks.example", "SOCKSPort": 1080,
        ])
        try expect(https == .proxy(scheme: "http", host: "proxy.example", port: 8443), "HTTPS before SOCKS")
        let socks = ProtonNetworkSettings.interpretSystem(["SOCKSEnable": 1, "SOCKSProxy": "socks.example", "SOCKSPort": 1080])
        try expect(socks == .proxy(scheme: "socks5", host: "socks.example", port: 1080), "SOCKS")
        let pac = ProtonNetworkSettings.interpretSystem([
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://127.0.0.1/proxy.pac",
            "HTTPSEnable": 1, "HTTPSProxy": "proxy.example", "HTTPSPort": 8443,
        ])
        try expect(pac == .pacIgnored && pac.wire == ProtonWireProxy(scheme: "direct", host: "", port: 0), "PAC stays direct")
        try expect(ProtonNetworkSettings.interpretSystem([:]) == .direct, "no proxy")
        let bypassed = ProtonNetworkSettings.interpretSystem([
            "HTTPSEnable": 1, "HTTPSProxy": "proxy.example", "HTTPSPort": 8443,
            "ExceptionsList": ["mail.proton.me"],
        ])
        try expect(bypassed == .direct, "ExceptionsList")
        let manual = ProtonHelperError.network.protonSyncMessage(mode: .manual, resolution: .proxy(scheme: "http", host: "127.0.0.1", port: 9))
        try expect(manual.contains("127.0.0.1:9") && manual.contains("无法连接 Proton"), "manual network copy")
        try expect(ProtonHelperError.network.kind == .network && ProtonHelperError.proxy.kind == .network, "proxy stays network")

        func script(_ name: String, _ source: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys,json\n" + source).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let seen = root.appendingPathComponent("missing-methods.log")
        let missing = try script("missing-configure", """
        for line in sys.stdin:
         r=json.loads(line)
         open('\(seen.path)','a').write(r['method']+'\\n')
         if r['method']=='hello':
          result={'protocol':1,'helper_version':'fixture','max_frame_bytes':8388608,'methods':['login','list','decrypt','logout']}
         else:
          result={'configured':True}
         print(json.dumps({'version':1,'id':r['id'],'result':result}),flush=True)
        """)
        try await fault(.protocolViolation) { _ = try await ProtonHelperClient(executable: missing).negotiate() }
        let methods = (try? String(contentsOf: seen, encoding: .utf8)) ?? ""
        try expect(methods == "hello\n", "helper without configure_network must not continue: \(methods)")

        let marker = root.appendingPathComponent("invalid-proxy-launched")
        let trap = try script("invalid-proxy", "open('\(marker.path)','w').write('launched')\n")
        UserDefaults.standard.setVolatileDomain([
            "protonProxyMode": "manual", "protonProxyManualScheme": "http",
            "protonProxyManualHost": "user@proxy.example", "protonProxyManualPort": 8080,
        ], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(["protonProxyMode": "direct"], forName: UserDefaults.argumentDomain) }
        do {
            _ = try await ProtonHelperClient(executable: trap).negotiate()
            throw TestFailure(name: "invalid proxy started")
        } catch is ProtonProxyConfigurationError {}
        try expect(!FileManager.default.fileExists(atPath: marker.path), "invalid proxy launched the helper")
        print("PASS: system proxy dictionaries, PAC direct, manual copy, fail closed")
    }
}
