import Foundation

enum RaceError: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let what): "\(what) took too long and was stopped."
        }
    }
}

/// Runs work that might get stuck (Apple's speech engine, the speaker models) so the caller
/// is never stuck with it: the caller gets the result, or a timeout error, or a cancellation —
/// whichever comes first. Stuck work is abandoned in the background and its result ignored.
enum Race {
    static func run<T: Sendable>(
        _ label: String,
        timeout: Duration? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let holder = Holder<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard holder.attach(continuation) else { return }  // Already cancelled.
                let work = Task.detached {
                    do {
                        holder.finish(.success(try await operation()))
                    } catch {
                        holder.finish(.failure(error))
                    }
                }
                var timer: Task<Void, Never>?
                if let timeout {
                    timer = Task.detached {
                        try? await Task.sleep(for: timeout)
                        if !Task.isCancelled { holder.finish(.failure(RaceError.timedOut(label))) }
                    }
                }
                holder.track(work: work, timer: timer)
            }
        } onCancel: {
            holder.finish(.failure(CancellationError()))
        }
    }

    /// Like `run`, but just reports whether the work finished in time.
    @discardableResult
    static func finishes(_ label: String, within timeout: Duration, _ operation: @escaping @Sendable () async throws -> Void) async -> Bool {
        do {
            try await run(label, timeout: timeout, operation)
            return true
        } catch {
            ActivityLog.add("\(label): \(error.localizedDescription)")
            return false
        }
    }

    private final class Holder<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var done = false
        private var pending: Result<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        /// Returns false if the race already ended (e.g. cancelled before it started).
        func attach(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            if let pending {
                lock.unlock()
                continuation.resume(with: pending)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func track(work: Task<Void, Never>, timer: Task<Void, Never>?) {
            lock.lock()
            if done {
                lock.unlock()
                work.cancel()
                timer?.cancel()
                return
            }
            self.work = work
            self.timer = timer
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { pending = result }
            let work = self.work
            let timer = self.timer
            lock.unlock()
            timer?.cancel()
            if case .failure = result { work?.cancel() }
            continuation?.resume(with: result)
        }
    }
}

/// Carries a value the compiler can't prove is safe to pass between tasks, for the cases
/// where it's handed over once and not shared.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
