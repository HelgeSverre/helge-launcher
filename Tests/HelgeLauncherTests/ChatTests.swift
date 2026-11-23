import Foundation
import Testing

@testable import HelgeLauncher

@Suite @MainActor struct ChatActivityTests {
    @Test func toolEventsBecomeActivities() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.send("rate?")
        await settle()
        ai.emit("s1", .thinking(true))
        #expect(c.turns[0].activities.map(\.tool) == ["thinking"])
        ai.emit("s1", .toolStarted(id: "t1", name: "websearch"))
        ai.emit("s1", .toolInput(id: "t1", detail: "usd nok"))
        ai.emit("s1", .toolEnded(id: "t1", ok: true, count: 4, error: nil))
        ai.emit("s1", .toolStarted(id: "t2", name: "webfetch"))
        ai.emit("s1", .toolEnded(id: "t2", ok: false, count: nil, error: "404"))
        let a = c.turns[0].activities
        #expect(a[0].state == .done)  // thinking ends when a tool starts
        #expect(a[1].detail == "usd nok" && a[1].resultCount == 4 && a[1].state == .done)
        #expect(a[2].state == .failed && a[2].error == "404")
        ai.emit("s1", .delta("9,75"))
        ai.emit("s1", .done)
        #expect(c.turns[0].done && c.turns[0].finished != nil)
        #expect(ActivityView.summary(c.turns[0]).hasPrefix("Searched once"))
    }

    @Test func aQuestionAskedWhileAnsweringIsSentAfterwards() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.send("one")
        await settle()
        c.sendOrQueue("two")
        #expect(c.queued == "two" && c.turns.count == 1)
        ai.emit("s1", .done)
        await settle()
        #expect(c.queued == nil && c.turns.map(\.question) == ["one", "two"])
        #expect(ai.prompts.map(\.text) == ["one", "two"])
    }

    @Test func stopKeepsWhatArrived() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.send("long")
        await settle()
        ai.emit("s1", .delta("partial"))
        c.stop()
        #expect(c.turns[0].done && c.turns[0].stopped && c.turns[0].answer == "partial")
        ai.emit("s1", .delta(" more"))
        #expect(c.turns[0].answer == "partial")
    }

    @Test func markdownExportHasEveryTurn() {
        let c = Conversation(
            backend: FakeAI(),
            turns: [
                ChatTurn(question: "Q1", answer: "**A1**", done: true),
                ChatTurn(question: "Q2", answer: "A2", done: true),
            ]
        )
        #expect(c.markdown() == "# Q1\n\n## You\n\nQ1\n\n## Assistant\n\n**A1**\n\n## You\n\nQ2\n\n## Assistant\n\nA2")
    }

    @Test func restoredChatSendsItsHistoryWithTheNextQuestion() async {
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        let saved = SavedChat(
            id: UUID(),
            title: "Old",
            created: Date(),
            updated: Date(),
            model: "m",
            turns: [ChatTurn(question: "earlier", answer: "reply", done: true)]
        )
        c.restore(saved)
        #expect(c.chatID == saved.id && c.turns.count == 1)
        c.send("next")
        await settle()
        let sent = ai.prompts.first?.text ?? ""
        #expect(sent.contains("earlier") && sent.contains("reply") && sent.hasSuffix("next"))
        ai.emit("s1", .done)
        c.send("again")
        await settle()
        #expect(ai.prompts.last?.text == "again")
    }

    @Test func storeSavesFinishedChatsNewestFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        let store = ChatStore(directory: dir)
        let ai = FakeAI()
        let c = Conversation(backend: ai)
        c.store = store
        c.send("first chat")
        await settle()
        ai.emit("s1", .delta("hi"))
        ai.emit("s1", .done)
        #expect(store.all().map(\.title) == ["first chat"])
        #expect(ChatStore(directory: dir).all().first?.turns.first?.answer == "hi")  // read back from disk
        store.delete(c.chatID)
        #expect(store.all().isEmpty)
    }
}

@Suite @MainActor struct ChatLauncherTests {
    func launcher(turns: Int) -> Launcher {
        let l = Launcher(ai: FakeAI())
        l.config.ai.enabled = true
        l.conversation = Conversation(
            backend: FakeAI(),
            turns: (1...turns).map {
                ChatTurn(question: "Q\($0)", answer: "A\($0)\n\n```sh\necho \($0)\n```", done: true)
            }
        )
        l.mode = .ai
        return l
    }

    @Test func optionArrowsWalkTheAnswers() {
        let l = launcher(turns: 3)
        l.moveMessage(-1)
        #expect(l.selectedTurn == l.conversation.turns[2].id)
        l.moveMessage(-1)
        l.moveMessage(-1)
        l.moveMessage(-1)
        #expect(l.selectedTurn == l.conversation.turns[0].id)
        l.moveMessage(1)
        l.moveMessage(1)
        l.moveMessage(1)
        #expect(l.selectedTurn == nil)
    }

    @Test func messageMenuRunsOnTheSelectedAnswer() {
        let l = launcher(turns: 2)
        l.moveMessage(-1)
        l.moveMessage(-1)
        l.stopOrMessageMenu()
        #expect(l.chatMenu == .message(l.conversation.turns[0].id))
        #expect(l.menuEntries.map(\.title).contains("Copy Code"))
        l.back()
        #expect(l.chatMenu == nil && l.selectedTurn != nil)
        l.back()
        #expect(l.selectedTurn == nil && l.mode == .ai)
    }

    @Test func quoteFillsTheField() {
        let l = launcher(turns: 1)
        l.quote()
        #expect(l.query == "About “A1”: ")
    }
}

@Suite struct MarkdownModelTests {
    @Test func gfmBlocks() {
        let md = """
            # Title

            | a | b |
            |:--|--:|
            | 1 | 2 |

            - [x] done
            - [ ] todo

            > [!NOTE]
            > Heads up

            ```swift
            let x = 1
            ```
            """
        let blocks = MarkdownModel.blocks(md)
        guard blocks.count == 5 else {
            Issue.record("got \(blocks.count) blocks")
            return
        }
        if case .heading(let level, _) = blocks[0] { #expect(level == 1) } else { Issue.record("heading") }
        if case .table(let h, let al, let rows) = blocks[1] {
            #expect(h.count == 2 && rows.count == 1 && al == [.leading, .trailing])
        } else {
            Issue.record("table")
        }
        if case .list(_, _, let items) = blocks[2] {
            #expect(items.map(\.checked) == [true, false])
        } else {
            Issue.record("tasks")
        }
        if case .alert(let kind, let inner) = blocks[3] {
            #expect(kind == .note && inner.count == 1)
        } else {
            Issue.record("alert")
        }
        if case .code(let lang, let text) = blocks[4] {
            #expect(lang == "swift" && text == "let x = 1")
        } else {
            Issue.record("code")
        }
    }

    @Test func plainTextAndCode() {
        let md = "Use **bold** and `code`.\n\n```\na\n```\n\n```py\nb\n```"
        #expect(MarkdownModel.plainText(md).hasPrefix("Use bold and code."))
        #expect(MarkdownModel.codeBlocks(md) == ["a", "b"])
    }

    @Test func unfinishedStreamStillParses() {
        #expect(!MarkdownModel.blocks("| a | b |\n|---|").isEmpty)
        #expect(!MarkdownModel.blocks("```swift\nlet x").isEmpty)
    }
}

@Suite struct HighlighterTests {
    func kinds(_ code: String, _ lang: String) -> [String: Highlighter.Token] {
        var out: [String: Highlighter.Token] = [:]
        for (t, k) in Highlighter.tokens(code, language: lang) where !t.trimmingCharacters(in: .whitespaces).isEmpty {
            out[t.trimmingCharacters(in: .whitespacesAndNewlines)] = k
        }
        return out
    }

    @Test func swift() {
        let k = kinds("let x = Int(\"5\") // n", "swift")
        #expect(k["let"] == .keyword && k["Int"] == .type && k["\"5\""] == .string && k["// n"] == .comment)
    }

    @Test func shell() {
        let k = kinds("du -sh $HOME | sort -rh # big", "zsh")
        #expect(k["du"] == .function && k["$HOME"] == .type && k["sort"] == .function && k["# big"] == .comment)
    }

    @Test func jsonKeysAndDiffLines() {
        let k = kinds("{\"a\": 1, \"b\": \"x\"}", "json")
        #expect(k["\"a\""] == .property && k["1"] == .number && k["\"x\""] == .string)
        let d = Highlighter.tokens("@@ x @@\n-old\n+new", language: "diff").map(\.1)
        #expect(d == [.meta, .removed, .added])
    }

    @Test func unknownLanguageStaysPlain() {
        #expect(Highlighter.tokens("anything", language: "brainfuck").map(\.1) == [.plain])
    }
}

@Suite struct EmojiTests {
    @Test func appleTablesCoverSequencesAndFlags() throws {
        try #require(FileManager.default.fileExists(atPath: Emoji.coreEmoji.path))
        let all = Emoji.all
        #expect(all.count > 1800)
        #expect(all.contains { $0.char == "🇳🇴" && $0.name == "Flag of Norway" })
        #expect(all.contains { $0.char == "👩\u{200D}🔧" })
        #expect(Emoji.lprojs(["nb-NO", "en"]) == ["no", "en"])
    }

    @Test func missingTablesFallBackToTheUnicodeScan() {
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("no-core-emoji")
        #expect(Emoji.load(languages: ["en"], in: none).count == Emoji.scanned.count)
    }
}
