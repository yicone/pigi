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
        print("Proton Swift regression: handshake, restart, faults, correlation, size, timeout and crash passed.")
    }
}
