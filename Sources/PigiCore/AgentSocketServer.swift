import Foundation
import Darwin

/// App-owned local transport. Clients never receive a database handle or credentials.
public final class AgentSocketServer: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pigi/agent.sock")
    }

    private let engine: LocalEngine
    private let url: URL
    private let audit: @Sendable (AgentProtocol.AuditEvent) -> Void
    private let lock = NSLock()
    private let lifecycle = NSLock()
    private var listener: Int32 = -1
    private var clients: Set<Int32> = []
    private var stopping = false
    private let listenerDone = DispatchGroup()
    private let slots = DispatchSemaphore(value: 8)

    public init(engine: LocalEngine = .shared, url: URL = AgentSocketServer.defaultURL,
                audit: @escaping @Sendable (AgentProtocol.AuditEvent) -> Void = { _ in }) {
        self.engine = engine; self.url = url; self.audit = audit
    }

    public enum StartupError: Error { case unsafePath, alreadyRunning, systemCall }

    /// Fail closed on unsafe paths and concurrent instances. Does not start syncing.
    public func start() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        lock.lock()
        defer { lock.unlock() }
        guard listener == -1 else { return }
        let directory = url.deletingLastPathComponent()
        try AppSupport.assertNotRealUserData(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), chmod(directory.path, 0o700) == 0 else { throw StartupError.unsafePath }
        // A persistent flock file serializes stale socket removal and listener ownership.
        let lockFD = open(url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw StartupError.unsafePath }
        var ownsLock = false
        var fd: Int32 = -1
        var bound = false
        var transferred = false
        defer {
            if !transferred {
                if fd >= 0 { close(fd) }
                if bound { unlink(url.path) }
                if ownsLock { flock(lockFD, LOCK_UN) }
                close(lockFD)
            }
        }
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, fchmod(lockFD, 0o600) == 0 else { throw StartupError.unsafePath }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw StartupError.alreadyRunning }
        ownsLock = true
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw StartupError.unsafePath }
            // Refuse to displace a live listener even if it predates our lock-file protocol.
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw StartupError.systemCall }
            defer { close(probe) }
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            let connected = try withAddress { connect(probe, $0, $1) }
            guard connected != 0, errno == ECONNREFUSED else { throw StartupError.alreadyRunning }
            guard unlink(url.path) == 0 else { throw StartupError.systemCall }
        } else if errno != ENOENT { throw StartupError.unsafePath }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartupError.systemCall }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard try withAddress({ bind(fd, $0, $1) }) == 0 else { throw StartupError.systemCall }
        bound = true
        guard chmod(url.path, 0o600) == 0, listen(fd, 8) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw StartupError.systemCall }
        guard lstat(url.path, &info) == 0 else { throw StartupError.systemCall }
        let inode = info.st_ino
        listener = fd; stopping = false
        let serverFD = fd
        listenerDone.enter()
        transferred = true
        DispatchQueue.global(qos: .utility).async { [self] in
            acceptLoop(serverFD)
            close(serverFD)
            // Never remove a replacement path installed by another process.
            var current = stat()
            if lstat(url.path, &current) == 0, current.st_ino == inode,
               current.st_mode & S_IFMT == S_IFSOCK { unlink(url.path) }
            flock(lockFD, LOCK_UN); close(lockFD)
            listenerDone.leave()
        }
    }

    /// Stops accepting and interrupts connected clients; callers may restart afterward.
    public func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        lock.lock()
        guard listener >= 0 else { lock.unlock(); return }
        stopping = true
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        listenerDone.wait()
        lock.lock(); listener = -1; lock.unlock()
    }

    private func withAddress<T>(_ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw StartupError.unsafePath }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock(); let done = stopping; lock.unlock()
            if done { return }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            lock.lock()
            if stopping { lock.unlock(); close(client); slots.signal(); return }
            clients.insert(client)
            lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in
                serve(client)
                lock.lock(); clients.remove(client); close(client); lock.unlock()
                slots.signal()
            }
        }
    }

    private func serve(_ fd: Int32) {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + 5_000_000_000
        var method = "invalid", outcome = "internal_error", id: String?
        defer {
            audit(.init(method: method, outcome: outcome,
                        durationMilliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)))
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var response: AgentProtocol.Response
        do {
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw AgentProtocol.Failure.make("unauthorized") }
            let data = try readFrame(fd, deadline: deadline)
            let request: AgentProtocol.Request
            do { request = try JSONDecoder().decode(AgentProtocol.Request.self, from: data) }
            catch { throw AgentProtocol.Failure.make("invalid_request") }
            if request.id.utf8.count <= 128 { id = request.id }
            if ["accounts", "list", "search", "get", "codes"].contains(request.method) { method = request.method }
            // Block this bounded transport worker, never the engine actor or main thread.
            let completion = DispatchSemaphore(value: 0)
            let box = ReadCompletion()
            Task { [engine] in
                do { box.value = .success(try await engine.agentRead(request)) }
                catch let failure as AgentProtocol.Failure { box.value = .failure(failure) }
                catch { box.value = .failure(.make("internal_error")) }
                completion.signal()
            }
            guard completion.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success else {
                throw AgentProtocol.Failure.make("timeout")
            }
            let result = try box.value!.get()
            response = .init(version: 1, id: id, result: result, error: nil)
            outcome = "ok"
        } catch {
            let failure = (error as? AgentProtocol.Failure) ?? .make("internal_error")
            outcome = failure.code
            response = .init(version: 1, id: id, result: nil, error: failure)
        }
        guard var encoded = try? JSONEncoder().encode(response) else { return }
        if encoded.count > AgentProtocol.maxResponseBytes {
            outcome = "too_large"
            encoded = (try? JSONEncoder().encode(AgentProtocol.Response(version: 1, id: id, result: nil, error: .make("too_large")))) ?? Data()
        }
        encoded.append(10)
        // Give errors a short write window even when the read deadline expired.
        let writeDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        encoded.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                guard wait(fd, event: Int16(POLLOUT), deadline: writeDeadline) else { break }
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n > 0 { sent += n }
                else if errno != EINTR && errno != EAGAIN { break }
            }
        }
    }

    private final class ReadCompletion: @unchecked Sendable {
        // Publication is synchronized by the completion semaphore.
        var value: Result<AgentProtocol.Result, AgentProtocol.Failure>?
    }

    private func wait(_ fd: Int32, event: Int16, deadline: UInt64) -> Bool {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
            var p = pollfd(fd: fd, events: event, revents: 0)
            let n = poll(&p, 1, Int32(min(remaining / 1_000_000 + 1, 1000)))
            if n > 0 { return p.revents & event != 0 }
            if n < 0 && errno != EINTR { return false }
        }
        return false
    }

    private func readFrame(_ fd: Int32, deadline: UInt64) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard wait(fd, event: Int16(POLLIN), deadline: deadline) else { throw AgentProtocol.Failure.make("timeout") }
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n > 0 else { throw AgentProtocol.Failure.make("invalid_request") }
            if let end = buffer[..<n].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end])
                guard data.count <= AgentProtocol.maxRequestBytes else { throw AgentProtocol.Failure.make("too_large") }
                return data
            }
            data.append(contentsOf: buffer[..<n])
            guard data.count <= AgentProtocol.maxRequestBytes else { throw AgentProtocol.Failure.make("too_large") }
        }
    }
}
