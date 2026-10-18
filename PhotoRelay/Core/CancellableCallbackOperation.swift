import Foundation

/// Bridges callback APIs whose cancellation is not guaranteed to deliver a
/// completion. Accepted callback work owns the operation until it has stopped;
/// callers may only clean up files or start another worker after that point.
final class CancellableCallbackOperation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let finalize: (Result<Value, Error>) -> Result<Value, Error>
    private var continuation: CheckedContinuation<Value, Error>?
    private var settledResult: Result<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var termination: (() -> Void)?
    private var activeWork = 0
    private var callbackClaimed = false
    private var terminal = false
    private var cancelled = false
    private var waitStarted = false

    init(finalize: @escaping (Result<Value, Error>) -> Result<Value, Error> = { $0 }) {
        self.finalize = finalize
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !terminal && !cancelled && pendingResult == nil }

    func wait(start: () -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                precondition(!waitStarted, "A callback operation can only be awaited once")
                waitStarted = true
                if let result = settledResult {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                let shouldStart = !terminal && !cancelled
                lock.unlock()
                // Cancellation may win between this check and start. Request
                // registration below immediately terminates that late request.
                if shouldStart { start() }
            }
        } onCancel: { self.cancel() }
    }

    /// Register after the framework returns its request handle. Synchronous
    /// completion or cancellation before registration cannot leak that handle.
    func registerTermination(_ action: @escaping () -> Void) {
        lock.lock()
        precondition(termination == nil, "Only one framework request is supported")
        let terminateNow = terminal || cancelled
        if !terminateNow { termination = action }
        lock.unlock()
        if terminateNow { action() }
    }

    /// For streaming chunks. Every accepted chunk finishes before finalization;
    /// callbacks arriving after cancellation/finish cannot touch the destination.
    func process(_ work: () throws -> Void) {
        guard beginWork(claimCompletion: false) else { return }
        let result: Result<Value, Error>?
        do { try work(); result = nil }
        catch { result = .failure(error) }
        endWork(result)
    }

    /// A provider's single final callback may do a bounded file copy while its
    /// temporary URL lease is valid. Duplicated callbacks never run the copy.
    func complete(_ work: () throws -> Value) {
        guard beginWork(claimCompletion: true) else { return }
        endWork(Result { try work() })
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        recordResultLocked(result)
        let final = takeFinalizationLocked()
        lock.unlock()
        if let final { settle(final) }
    }

    func cancel() {
        lock.lock()
        guard !terminal, !cancelled else { lock.unlock(); return }
        cancelled = true
        pendingResult = .failure(CancellationError())
        let action = termination
        termination = nil
        let final = takeFinalizationLocked()
        lock.unlock()
        // No external API or continuation executes while our lock is held.
        action?()
        if let final { settle(final) }
    }

    private func beginWork(claimCompletion: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !terminal, !cancelled, pendingResult == nil else { return false }
        if claimCompletion {
            guard !callbackClaimed else { return false }
            callbackClaimed = true
        }
        activeWork += 1
        return true
    }

    private func endWork(_ result: Result<Value, Error>?) {
        lock.lock()
        activeWork -= 1
        recordResultLocked(result)
        let final = takeFinalizationLocked()
        lock.unlock()
        if let final { settle(final) }
    }

    private func recordResultLocked(_ result: Result<Value, Error>?) {
        guard let result, !cancelled else { return }
        // A provider completion can race its last data callback. A write error
        // must win over a success completion that is waiting for that callback.
        if case .failure = result {
            if case .failure? = pendingResult { return }
            pendingResult = result
        } else if pendingResult == nil {
            pendingResult = result
        }
    }

    private func takeFinalizationLocked() -> Result<Value, Error>? {
        guard !terminal, activeWork == 0, let result = pendingResult else { return nil }
        terminal = true
        return result
    }

    private func settle(_ result: Result<Value, Error>) {
        // terminal has already been claimed, so no new callback work can enter.
        let result = finalize(result)
        lock.lock()
        settledResult = result
        let continuation = continuation
        self.continuation = nil
        let action = termination
        termination = nil
        lock.unlock()
        action?()
        continuation?.resume(with: result)
    }
}
