import Foundation

/// A system service (the on-device model, Vision) that never answers would otherwise stall
/// a whole run. This returns nil after `seconds` and leaves the stuck call behind: it may
/// ignore cancellation, so waiting for it to stop could hang just the same. Cancelling the
/// caller (Organize Now's Cancel) ends the wait at once, with `CancellationError`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            race.start(continuation,
                       work: Task {
                           do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
                       },
                       timer: Task {
                           try? await Task.sleep(for: .seconds(seconds))
                           race.finish(.success(nil))
                       })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Whoever finishes first (the work, the timer, a cancel) resumes the caller; the rest are ignored.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Error>?
    private var early: Result<T?, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var done = false

    func start(_ continuation: CheckedContinuation<T?, Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
        let finished: Result<T?, Error>? = lock.withLock {
            tasks = [work, timer]
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        // Cancelled before it even started.
        if let finished { work.cancel(); timer.cancel(); continuation.resume(with: finished) }
    }

    func finish(_ result: Result<T?, Error>) {
        let (waiting, others): (CheckedContinuation<T?, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !done else { return (nil, []) }
            done = true
            guard let continuation else { early = result; return (nil, []) }
            self.continuation = nil
            return (continuation, tasks)
        }
        others.forEach { $0.cancel() }
        waiting?.resume(with: result)
    }
}
