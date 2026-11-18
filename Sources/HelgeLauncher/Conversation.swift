import Foundation

struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    var question: String
    var answer: String = ""
    var status: String = ""
    var done = false
}

/// One AI conversation. At most one prompt is in flight; `reset()` starts a new conversation and
/// drops every event and session result that belongs to the old one.
@MainActor
final class Conversation: ObservableObject {
    @Published private(set) var turns: [ChatTurn]

    private let backend: AIBackend
    private var epoch = 0
    private var session: AISession?
    private var creating: Task<AISession, Error>?

    init(backend: AIBackend, turns: [ChatTurn] = []) {
        self.backend = backend
        self.turns = turns
    }

    var isBusy: Bool { turns.last.map { !$0.done } ?? false }
    var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }

    /// Returns false while a previous answer is still streaming.
    @discardableResult
    func send(_ question: String) -> Bool {
        guard !isBusy else { return false }
        let turn = ChatTurn(question: question, status: "Thinking…")
        turns.append(turn)
        run(question, turn: turn.id, epoch: epoch, retryOnLostSession: true)
        return true
    }

    func reset() {
        if let s = session {
            backend.release(s)
            if isBusy { Task { await backend.interrupt(s) } }
        }
        epoch += 1
        session = nil
        creating?.cancel()
        creating = nil
        turns = []
    }

    private func run(_ question: String, turn: UUID, epoch: Int, retryOnLostSession: Bool) {
        Task {
            do {
                let s = try await currentSession(epoch: epoch)
                guard epoch == self.epoch else { return }
                try await backend.prompt(s, text: question) { [weak self] event in
                    self?.apply(event, turn: turn, epoch: epoch)
                }
            } catch AIError.sessionLost where retryOnLostSession {
                guard epoch == self.epoch else { return }
                session = nil
                run(question, turn: turn, epoch: epoch, retryOnLostSession: false)
            } catch {
                apply(.failed(error.localizedDescription), turn: turn, epoch: epoch)
            }
        }
    }

    private func currentSession(epoch: Int) async throws -> AISession {
        if let s = session { return s }
        if let pending = creating { return try await pending.value }
        let task = Task { try await backend.createSession() }
        creating = task
        do {
            let s = try await task.value
            if epoch == self.epoch {
                session = s
                creating = nil
            }
            return s
        } catch {
            if epoch == self.epoch { creating = nil }
            throw error
        }
    }

    private func apply(_ event: AIEvent, turn: UUID, epoch: Int) {
        guard epoch == self.epoch, let i = turns.firstIndex(where: { $0.id == turn }), !turns[i].done else { return }
        switch event {
        case .delta(let d):
            turns[i].answer += d
            turns[i].status = ""
        case .tool(let t): turns[i].status = "Using \(t)…"
        case .done:
            turns[i].done = true
            turns[i].status = ""
        case .failed(let e):
            turns[i].done = true
            turns[i].status = "Failed: \(e)"
        }
    }
}
