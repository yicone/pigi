import Foundation
import Observation
#if canImport(PigiCore)
import PigiCore
#endif

/// Only the current challenge reaches the view. Credentials stay in the private
/// login call; cancellation/timeout always resolves the suspended request.
@MainActor @Observable
final class ProtonLoginPrompt {
    var pending: ProtonLoginChallenge?
    var answer = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?

    func request(_ challenge: ProtonLoginChallenge) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                pending = challenge; answer = ""
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.finish(.failure(ProtonHelperError.loginExpired))
                }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        pending = nil; answer = ""
        continuation.resume(with: result)
    }
    func submit() { finish(.success(answer)) }
    func cancel() { finish(.failure(CancellationError())) }
}
