# AI

Helge Launcher answers questions through [opencode](https://opencode.ai), running as a local server. The default model is `opencode-go/deepseek-v4.1-flash`; any model `opencode models` lists works.

## Using it

| Where | Key | Does |
|---|---|---|
| Main search | Tab | Sends what you typed to the AI |
| Main search | ↵ on "Ask AI: …" | Same. The item is listed first when nothing else matches well, otherwise last. |
| Main search | "AI Chat" command | Opens an empty chat |
| Chat | ↵ | Sends a follow-up in the same conversation |
| Chat | ↵ with an empty field | Copies the last answer |
| Chat | ⌘N | Starts a new conversation |
| Chat | Esc | Back to the search |

The conversation stays while the app runs: closing and reopening the launcher returns to it. Answers stream in as they are written; inline Markdown (bold, italics, `code`, links) is rendered.

## What the AI can do

Each conversation is an opencode session with these permissions:

| Tool | Allowed |
|---|---|
| `webfetch`, `websearch` | yes: it can look things up and read web pages |
| everything else (shell, file reads and edits, …) | no |

It runs in its own empty working directory, `~/Library/Application Support/HelgeLauncher/ai`, so it never sees your projects. While it uses a tool, the chat shows "Using …" under the answer.

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

- At launch (and when the config changes) the launcher starts `opencode serve --hostname 127.0.0.1 --port 0` as a child process, with a random password. It reads the chosen port from the server's output. The server stops when the launcher quits.
- Each conversation is a session created with `POST /api/session` (model and permissions above). Questions go to `POST /api/session/{id}/prompt`.
- Answers arrive over one server-sent-events stream (`GET /api/event`), filtered to text deltas, tool calls and completion.
- The server only listens on localhost and requires the password, which never leaves the process.

Test from a terminal without the UI:

```sh
HelgeLauncher --ai "What does open -a do?"
# or from the repository: just ask "What does open -a do?"
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Error: … did not start" | The `opencode` binary wasn't found, or it's an old one. The launcher uses your interactive zsh's `PATH`; check `which -a opencode`. An outdated Homebrew `opencode` (1.x) earlier on `PATH` than the current one breaks the v2 API. Run `brew uninstall opencode`, or set `opencode = "~/.bun/bin/opencode"`. |
| "Failed: …" under the answer | The model or provider rejected the request: log in with `opencode auth login`, or check the model name with `opencode models`. |
| Answers that look like raw tool-call markup | The model tried a tool that is denied. Rephrase, or ask it to answer without tools. |
| Nothing happens | Check that `[ai] enabled` isn't `false` and the config has no error (shown in the footer). |
