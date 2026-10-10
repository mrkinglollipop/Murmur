import Foundation

/// A one-shot race that can return after its deadline even when the operation
/// is blocked in code that does not cooperate with task cancellation.
enum AsyncDeadline {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = DeadlineRaceState<Value>()
        let operationTask = Task<Void, Never> {
            do {
                race.resolve(.success(try await operation()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let timeoutTask = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: seconds))
            } catch {
                return
            }
            if race.resolve(.failure(timeoutError())) {
                operationTask.cancel()
            }
        }
        race.installTimeoutTask(timeoutTask)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.installContinuation(continuation)
            }
        } onCancel: {
            if race.resolve(.failure(CancellationError())) {
                operationTask.cancel()
            }
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        let clamped = max(0, min(seconds, TimeInterval(UInt64.max) / 1_000_000_000))
        return UInt64(clamped * 1_000_000_000)
    }
}

private final class DeadlineRaceState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    func installContinuation(_ newContinuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            newContinuation.resume(with: result)
        } else {
            continuation = newContinuation
            lock.unlock()
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ newResult: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = newResult
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: newResult)
        return true
    }
}
