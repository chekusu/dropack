import Foundation

/// One coordinated read per instance. Cancellation also cancels the provider's
/// pending coordination, rather than only being noticed after its download ends.
final class AlbumPreviewFileCoordinator: @unchecked Sendable {
    typealias Read = @Sendable (URL, (URL) -> Void) -> Error?
    private let reader: Read
    private let cancellation: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false

    convenience init() {
        let coordinator = NSFileCoordinator()
        self.init(read: { url, accessor in
            var error: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: accessor)
            return error
        }, cancel: { coordinator.cancel() })
    }

    /// Injection models a file provider blocked before granting access; tests
    /// need no network account, mounted drive, or large fixture.
    init(read: @escaping Read, cancel: @escaping @Sendable () -> Void) {
        reader = read; cancellation = cancel
    }

    func read<T>(_ url: URL, body: (URL) throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try checkCancellation()
            var result: Result<T, Error>?
            let error = reader(url) { local in
                result = Result {
                    try self.checkCancellation()
                    return try body(local)
                }
            }
            // A provider may return success or an unrelated error while its
            // cancellation unwinds. Never publish its result after dismissal.
            try checkCancellation()
            if let error { throw error }
            guard let result else { throw AlbumMediaPreviewError.unavailable }
            return try result.get()
        } onCancel: { self.cancel() }
    }

    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        cancellation()
    }
}
