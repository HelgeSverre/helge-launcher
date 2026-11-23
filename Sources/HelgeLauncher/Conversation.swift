import Foundation

/// Something the AI did while answering: thinking, a web search, a page read.
struct ChatActivity: Identifiable, Equatable, Codable {
    enum State: String, Codable {
        case running, done, failed
    }

    var id: String
    /// opencode tool name ("websearch", "webfetch"), or "thinking".
    var tool: String
    var detail = ""
    var started = Date()
    var ended: Date?
    var state = State.running
    var resultCount: Int?
    var error: String?

    var isThinking: Bool { tool == "thinking" }
    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }
}

struct ChatTurn: Identifiable, Equatable, Codable {
    var id = UUID()
    var question: String
    var answer: String = ""
    var activities: [ChatActivity] = []
    var started = Date()
    var finished: Date?
    var error: String?
    var stopped = false
    var done = false

    /// "Failed: …" for a failed turn, else empty.
    var status: String { error.map { "Failed: \($0)" } ?? "" }

    init(question: String, answer: String = "", done: Bool = false) {
        self.question = question
        self.answer = answer
        self.done = done
        if done { finished = started }
    }
}

/// A conversation as saved: what the history lists and restores.
struct SavedChat: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var model: String
    var turns: [ChatTurn]
}

/// One AI conversation. At most one prompt is in flight; a question asked meanwhile waits in `queued`.
/// `reset()` starts a new conversation and drops every event and session result of the old one.
@MainActor
final class Conversation: ObservableObject {
    @Published private(set) var turns: [ChatTurn]
    @Published private(set) var queued: String?
    private(set) var chatID = UUID()
    private(set) var created = Date()
    var model = ""
    /// Persists finished turns; nil keeps the conversation in memory only.
    var store: ChatStore?

    private let backend: AIBackend
    private var epoch = 0
    private var session: AISession?
    private var creating: Task<AISession, Error>?
    /// A restored conversation sends its earlier turns with the next question.
    private var seedHistory = false

    init(backend: AIBackend, turns: [ChatTurn] = []) {
        self.backend = backend
        self.turns = turns
    }

    var isBusy: Bool { turns.last.map { !$0.done } ?? false }
    var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }
    var title: String { Conversation.title(turns.first?.question ?? "") }

    static func title(_ question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    /// Returns false while a previous answer is still streaming.
    @discardableResult
    func send(_ question: String) -> Bool {
        guard !isBusy else { return false }
        let turn = ChatTurn(question: question)
        turns.append(turn)
        var text = question
        if seedHistory {
            text = Conversation.transcript(turns.dropLast()) + "\n\nContinuing the conversation above:\n\n" + question
            seedHistory = false
        }
        run(text, turn: turn.id, epoch: epoch, retryOnLostSession: true)
        return true
    }

    /// Sends now, or after the current answer.
    func sendOrQueue(_ question: String) {
        if !send(question) { queued = question }
    }

    /// Interrupts the answer in progress; what arrived so far stays.
    func stop() {
        guard isBusy, let i = turns.indices.last else { return }
        if let s = session { Task { await backend.interrupt(s) } }
        turns[i].stopped = true
        finish(i)
        queued = nil
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
        queued = nil
        chatID = UUID()
        created = Date()
        seedHistory = false
    }

    /// Continues a saved conversation; the next question carries the earlier turns to a new session.
    func restore(_ chat: SavedChat) {
        reset()
        chatID = chat.id
        created = chat.created
        turns = chat.turns.map { t in
            var t = t
            if !t.done {
                t.done = true
                t.stopped = true
            }
            return t
        }
        seedHistory = !turns.isEmpty
    }

    var saved: SavedChat {
        SavedChat(
            id: chatID,
            title: title,
            created: created,
            updated: turns.last?.finished ?? Date(),
            model: model,
            turns: turns
        )
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
            endThinking(i)
        case .thinking(let on):
            if on {
                turns[i].activities.append(ChatActivity(id: "thinking-\(turns[i].activities.count)", tool: "thinking"))
            } else {
                endThinking(i)
            }
        case .toolStarted(let id, let name):
            endThinking(i)
            turns[i].activities.append(ChatActivity(id: id, tool: name))
        case .toolInput(let id, let detail):
            if let k = turns[i].activities.firstIndex(where: { $0.id == id }) {
                turns[i].activities[k].detail = detail
            } else {
                turns[i].activities.append(ChatActivity(id: id, tool: "tool", detail: detail))
            }
        case .toolEnded(let id, let ok, let count, let error):
            if let k = turns[i].activities.firstIndex(where: { $0.id == id }) {
                turns[i].activities[k].state = ok ? .done : .failed
                turns[i].activities[k].ended = Date()
                turns[i].activities[k].resultCount = count
                turns[i].activities[k].error = error
            }
        case .done:
            finish(i)
        case .failed(let e):
            turns[i].error = e
            finish(i)
        }
    }

    private func endThinking(_ i: Int) {
        for k in turns[i].activities.indices
        where turns[i].activities[k].isThinking && turns[i].activities[k].state == .running {
            turns[i].activities[k].state = .done
            turns[i].activities[k].ended = Date()
        }
    }

    private func finish(_ i: Int) {
        endThinking(i)
        for k in turns[i].activities.indices where turns[i].activities[k].state == .running {
            turns[i].activities[k].state = .done
            turns[i].activities[k].ended = Date()
        }
        turns[i].done = true
        turns[i].finished = Date()
        store?.save(saved)
        if let q = queued {
            queued = nil
            send(q)
        }
    }

    // MARK: Markdown

    /// The conversation as Markdown: a title, then each question and answer.
    func markdown() -> String {
        "# \(title)\n\n" + Conversation.transcript(turns[...])
    }

    static func transcript(_ turns: ArraySlice<ChatTurn>) -> String {
        turns.map { t in
            var s = "## You\n\n\(t.question)\n\n## Assistant\n\n"
            s += t.answer.isEmpty ? (t.error.map { "_Failed: \($0)_" } ?? "_No answer_") : t.answer
            return s
        }.joined(separator: "\n\n")
    }
}

/// Saved conversations: one JSON file per chat in `<support>/chats`.
@MainActor
final class ChatStore {
    static let shared = ChatStore(directory: Paths.supportDir.appendingPathComponent("chats"))

    let directory: URL
    private var cache: [SavedChat]?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func save(_ chat: SavedChat) {
        guard !chat.turns.isEmpty, let data = try? ChatStore.encoder.encode(chat) else { return }
        try? data.write(to: file(chat.id), options: .atomic)
        if var c = cache {
            c.removeAll { $0.id == chat.id }
            c.insert(chat, at: 0)
            cache = c
        }
    }

    /// Newest first.
    func all() -> [SavedChat] {
        if let c = cache { return c }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let chats = files.filter { $0.pathExtension == "json" }
            .compactMap { try? ChatStore.decoder.decode(SavedChat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
        cache = chats
        return chats
    }

    func chat(_ id: UUID) -> SavedChat? { all().first { $0.id == id } }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        cache?.removeAll { $0.id == id }
    }
}
