import Foundation

/// Resumes a continuation at most once, from any thread.
final class ResumeOnce<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Error>) { cont = c }

    var isDone: Bool { lock.withLock { cont == nil } }

    func resume(returning v: T) { take()?.resume(returning: v) }
    func resume(throwing e: Error) { take()?.resume(throwing: e) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { cont = nil }
            return cont
        }
    }
}

final class LockedBuffer: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.withLock { storage.append(d) } }
    var data: Data { lock.withLock { storage } }
    var text: String { String(decoding: data, as: UTF8.self) }
}

final class LockedFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
