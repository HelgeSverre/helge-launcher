# AI

Helge Launcher answers questions through [opencode](https://opencode.ai), running as a local server. The default model is `opencode-go/deepseek-v4.1-flash`; any model `opencode models` lists works.

## Using it

| Where | Key | Does |
|---|---|---|
| Main search | Tab | Sends what you typed to the AI |
| Main search | ↵ on "Ask AI: …" | Same. The item is listed first when nothing else matches well, otherwise last. |
| Main search | "AI Chat" / "AI Conversations" | Opens an empty chat / the saved conversations |
| Anywhere | ⌘Y | Saved conversations |
| Chat | ↵ | Sends a follow-up; while an answer streams, the question waits and is sent after it |
| Chat | ↵ with an empty field | Copies the last answer |
| Chat | ⌘. | Stops the answer in progress; otherwise opens the message menu |
| Chat | ⌥↑ ⌥↓ | Selects an earlier answer (Esc clears the selection) |
| Chat | ⌘C | Copies the selected answer as Markdown (when the field has no selection) |
| Chat | ⇧⌘C / ⌘↵ | Copies / pastes the code blocks of the selected (or last) answer |
| Chat | ⌘R / ⇧⌘R | Quotes the answer in a follow-up / asks its question again |
| Chat | ⌥⌘C / ⌘S | Copies the chat as Markdown / saves it to Downloads as a .md file |
| Chat | ⌘N / ⌘⌫ | New chat / deletes this chat |
| Chat | ⌘K | All chat actions; hovering an answer shows its ⋮ menu |
| Conversations | ↵ / ⌘C | Continues the chat / copies it as Markdown |
| Chat, Conversations | Esc | Back |

Answers render GitHub-flavored Markdown: headings, lists and task lists, tables with column alignment, quotes, `> [!NOTE]`-style alerts, links and code blocks with syntax colouring (Swift, shell, JSON, Python, JS/TS, Go, Rust, C-family, SQL, YAML, TOML, CSS, HTML/XML and diffs) and a Copy button. Remote images show as links.

While it works, the chat lists what the AI does: searches with their query and result count, pages read, and thinking, each with its duration. When the answer is done the list folds into one line ("Searched once · read 2 pages · 6,9 s") that expands on click.

Every finished turn is saved to `~/Library/Application Support/HelgeLauncher/chats/<id>.json`; the conversation list searches titles and every message. Continuing an old chat starts a new opencode session and sends the earlier turns along with the next question.

## What the AI can do

Each conversation is an opencode session with these permissions:

| Tool | Allowed |
|---|---|
| `webfetch`, `websearch` | yes: it can look things up and read web pages |
| everything else (shell, file reads and edits, …) | no |

It runs in its own empty working directory, `~/Library/Application Support/HelgeLauncher/ai`, so it never sees your projects.

## Setup

1. Install opencode (`bun install -g @opencode/cli`, or see [opencode.ai](https://opencode.ai)) and log in to the provider you want (`opencode auth login`). The default model needs an [OpenCode Go](https://opencode.ai) subscription.
2. Check that the model works: `opencode run -m opencode-go/deepseek-v4.1-flash "hi"`.
3. Optional, in `~/.config/hl/config.toml`:

   ```toml
   [ai]
   model = "opencode-go/deepseek-v4.1-flash"   # provider/model from `opencode models`
   opencode = "opencode"                        # or a full path to the binary
   system = "Answer briefly. Use metric units."  # sent before every question
   ```

Set `enabled = false` to remove the AI items and stop the server.

## How it works

- At launch (and when the config changes) the launcher starts `opencode serve --stdio --hostname 127.0.0.1 --port 0` as a child process, with a random password, and reads the server's address from its first line of output. The server's stdin is a pipe held by the launcher: when the launcher quits or crashes, the pipe closes and the server shuts down.
- If the server exits, the next question starts a new one. Changing `opencode` or setting `enabled = false` stops it; a `model` change applies to new chats (⌘N).
- One question is answered at a time; asking while an answer is streaming shows "Still answering".
- Each conversation is a session created with `POST /api/session` (model and permissions above). Questions go to `POST /api/session/{id}/prompt`.
- Answers arrive over one server-sent-events stream (`GET /api/event`), filtered to text deltas, reasoning start/end, tool input, success and failure, and completion. `HL_AI_EVENTS=1 HelgeLauncher --ai "…"` prints every raw event to stderr.
- The server only listens on localhost and requires the password, which never leaves the process.

Test from a terminal without the UI:

```sh
HelgeLauncher --ai "What does open -a do?"
# or from the repository: just ask "What does open -a do?"
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Failed: opencode serve did not start: …" | The `opencode` binary wasn't found, or it's an old one. The launcher uses your interactive zsh's `PATH`; check `which -a opencode`. An outdated Homebrew `opencode` (1.x) earlier on `PATH` than the current one breaks the v2 API. Run `brew uninstall opencode`, or set `opencode = "~/.bun/bin/opencode"`. |
| Any other "Failed: …" under the answer | The model or provider rejected the request: log in with `opencode auth login`, or check the model name with `opencode models`. |
| Answers that look like raw tool-call markup | The model tried a tool that is denied. Rephrase, or ask it to answer without tools. |
| Nothing happens | Check that `[ai] enabled` isn't `false` and the config has no error (shown in the footer). |
