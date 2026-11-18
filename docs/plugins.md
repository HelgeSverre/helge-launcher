# Plugins

A plugin is any program that prints a list as JSON. Helge Launcher runs it with what you typed, shows the list, and performs the action you pick: open a URL, copy or paste text, or run a shell command. Write it in whatever you like: shell, Python, Bun/TypeScript, [Sema](https://sema-lang.com), a compiled binary.

## Your first plugin

1. Save this as `~/.config/hl/plugins/hello.sh` and make it executable (`chmod +x`):

   ```sh
   #!/bin/sh
   # $1 is what you typed after opening the plugin.
   cat <<JSON
   {"items": [
     {"title": "Hello, ${1:-world}", "icon": "hand.wave",
      "actions": [{"title": "Copy", "copy": "Hello, ${1:-world}"}]}
   ]}
   JSON
   ```

2. Add it to `~/.config/hl/config.toml`:

   ```toml
   [[plugin]]
   name = "Hello"
   exec = "plugins/hello.sh"
   prefix = "hi"
   ```

3. Save. The config reloads by itself. Open the launcher and type `hi Helge`. Enter copies "Hello, Helge".

## How a plugin runs

```
you type "hi Helge"
   │  prefix "hi" + space → the launcher switches to the Hello plugin with query "Helge"
   ▼
plugins/hello.sh Helge          ← runs again on every keystroke (120 ms debounce)
   │  stdout: {"items":[…]}
   ▼
the list is shown as returned  → ↵ runs the first action, ⌘↵ the second, ⌘K lists all
```

- **Opening a plugin.** Every plugin is listed in the main search under its `name`. Select it with ↵, or type its `prefix` followed by a space to jump in with the rest as the query. Esc, or ⌫ on an empty field, goes back.
- **The query** is the last command-line argument and is also in `$HL_QUERY`. It is `""` right after the plugin opens.
- **Every keystroke** starts a new run after 120 ms of quiet. A newer run replaces an older one, so slow plugins never show stale results.
- **Working directory** is the config directory (`~/.config/hl`), so relative paths in `exec` and inside the plugin resolve there.
- **Timeout:** 15 seconds. The process is then killed and the error is shown as an item.
- **Order:** items are shown exactly in the order printed; the launcher does not re-rank or filter them. Filter by the query yourself, and keep the list short (about 50 items).

### Environment

| Variable | Value |
|---|---|
| `HL_QUERY` | The query (same as the last argument) |
| `HL_CONFIG_DIR` | The config directory, normally `~/.config/hl` |
| `PATH` | The `PATH` of your interactive zsh, so `gh`, `bun`, `sema`, `jq`, … are found |
| anything in `env` | From the plugin's `env` table in the config (see below) |

The launcher starts from Finder, not from your terminal, so variables exported in `~/.zshrc` (except `PATH`) are not visible to plugins. Put the ones a plugin needs in its `env` table.

## Configuration

```toml
[[plugin]]
name = "Notes"                                         # shown in the main search (required)
exec = ["sema", "--no-llm", "plugins/notes.sema", "--"] # program, or program + arguments (required)
prefix = "n"                                           # "n " jumps straight in (optional)
icon = "note.text"                                     # icon for the entry and for items without one
env = { NOTES_DIR = "~/Documents/Notes" }              # extra environment; values may start with ~
```

| Key | Type | Meaning |
|---|---|---|
| `name` | string | Entry title in the main search; also the plugin's identity in `--plugin` |
| `exec` | string or list of strings | `"plugins/x.sh"` runs that file. `["prog", "arg", …]` runs `prog` with those arguments. The query is appended as the last argument either way. A first word without `/` is looked up on `PATH`; relative paths resolve against the config directory; `~` works. |
| `prefix` | string | Typing `prefix` + space in the main search opens the plugin with the rest as the query. Without a prefix, open it from the list. |
| `icon` | string | SF Symbol name, emoji, or image path (see [Icons](#icons)). Default `puzzlepiece.extension`. |
| `env` | table | Extra environment variables for the plugin process |

Use the list form when the program is an interpreter that needs flags before the script, such as Sema (`["sema", "--no-llm", "plugins/x.sema", "--"]`, see [Writing plugins in Sema](#writing-plugins-in-sema)) or `["python3", "-I", "plugins/x.py"]`.

## Output format

Print one JSON object to stdout and exit 0:

```json
{
  "items": [
    {
      "id": "repo-42",
      "title": "HelgeSverre/helge-launcher",
      "subtitle": "Keyboard launcher for macOS",
      "icon": "book.closed",
      "accessory": "public",
      "actions": [
        { "title": "Open", "open": "https://github.com/HelgeSverre/helge-launcher" },
        { "title": "Copy Clone URL", "copy": "git@github.com:HelgeSverre/helge-launcher.git" },
        { "title": "Open Issues", "open": "https://github.com/HelgeSverre/helge-launcher/issues" }
      ]
    }
  ]
}
```

### Item

| Field | Required | Meaning |
|---|---|---|
| `title` | yes | Main text |
| `subtitle` | no | Grey text after the title |
| `icon` | no | SF Symbol, emoji or image path. Falls back to the plugin's `icon`, then a circle. |
| `accessory` | no | Small mono label on the right ("private", "PR", "3 days") |
| `id` | no | Unique identity within the list. Defaults to the position and title; set it when two items can share a title. |
| `actions` | no | List of actions. An item without actions is display-only: ↵ does nothing. |

An empty list (`{"items": []}`) shows "No results".

### Action

| Field | Does |
|---|---|
| `title` | Label in the footer and the ⌘K menu (required) |
| `open` | Opens a URL (`https://…`, `obsidian://…`, `x-apple.systempreferences:…`), a file or folder path, or an app path, with the default handler |
| `copy` | Puts the text on the clipboard |
| `paste` | Puts the text on the clipboard and pastes it into the app you came from (needs Accessibility, see the README) |
| `run` | Runs the string with `zsh -lc` in the background. Output is discarded; the launcher does not wait. |

- ↵ runs the item's first action, ⌘↵ the second, ⌘K shows all of them.
- The panel closes after an action runs.
- One action may combine several fields; they run in the order `open`, `copy`, `paste`, `run`.
- For `run`, quote anything that comes from data. In shell, use single quotes and escape embedded ones; Sema has `shell/quote`, Python has `shlex.quote`.

### Icons

| Value | Shown as |
|---|---|
| `"star"`, `"book.closed"`, `"cpu"` | [SF Symbol](https://developer.apple.com/sf-symbols/) of that name |
| `"🚀"` | That emoji |
| `"/path/to/image.png"`, `"~/icon.png"`, `"/Applications/Slack.app"` | The image, or the file's Finder icon |

### Errors

Errors are shown as a single item titled "*name* failed" with the reason as the subtitle:

| Situation | Subtitle |
|---|---|
| Non-zero exit | The plugin's stderr (or `exit N` when stderr is empty) |
| stdout is not valid JSON in this format | The decoding error |
| More than 15 seconds | "… timed out after 15s" |
| `exec` not found / not executable | The `env` error, e.g. "No such file or directory" |

Write diagnostics to **stderr**; anything else on stdout breaks the JSON. For expected failures (no network, not logged in), print an item yourself, as the examples do, so the message reads well.

## Testing a plugin

Run it through the launcher's own plugin code, without opening the UI:

```sh
HelgeLauncher --plugin "Hello" --search "Helge"
# or, from the repository:
just plugin Hello Helge
```

```
Hello, Helge
    · Copy: copy Hello, Helge
```

It prints every item with its subtitle and accessory, and every action with what it would do. It uses the same arguments, environment, working directory and timeout as the panel.

To try a config without touching your real one, point `HL_CONFIG_DIR` at a scratch directory:

```sh
mkdir -p /tmp/hl/plugins && cp my-plugin.sh /tmp/hl/plugins/
printf '[[plugin]]\nname = "Mine"\nexec = "plugins/my-plugin.sh"\n' > /tmp/hl/config.toml
HL_CONFIG_DIR=/tmp/hl HelgeLauncher --plugin Mine --search test
```

You can also run the script directly (`plugins/hello.sh Helge | jq .`); the launcher adds only the environment above.

`HelgeLauncher` is `/Applications/Helge Launcher.app/Contents/MacOS/HelgeLauncher`; alias it if you use it often.

## Examples

All examples are in [`docs/examples/plugins`](examples/plugins) and have been run through `--plugin` as shown above. Copy one into `~/.config/hl/plugins/` and add the config block from the table.

| Plugin | Language | What it does | Config |
|---|---|---|---|
| [hello.sh](examples/plugins/hello.sh) | sh | Echoes the query; copy and open actions | `exec = "plugins/hello.sh"` |
| [calc.py](examples/plugins/calc.py) | Python | Calculator; pastes the result. Evaluates only arithmetic. | `exec = "plugins/calc.py"`, `prefix = "="` |
| [processes.sh](examples/plugins/processes.sh) | zsh + awk | Running processes by name; quit, force kill, copy PID | `exec = "plugins/processes.sh"`, `prefix = "ps"` |
| [github-repos.ts](examples/plugins/github-repos.ts) | Bun | Your GitHub repositories via `gh`; open, copy clone URL, open issues | `exec = "plugins/github-repos.ts"`, `prefix = "gh"` |
| [units.sema](examples/plugins/units.sema) | Sema | Unit converter: `10 km in mi`, `72 f to c`, `1 gib to mb` | `exec = ["sema", "--no-llm", "plugins/units.sema", "--"]`, `prefix = "u"` |
| [hacker-news.sema](examples/plugins/hacker-news.sema) | Sema | Hacker News front page, or story search; open link or comments | `exec = ["sema", "--no-llm", "plugins/hacker-news.sema", "--"]`, `prefix = "hn"` |
| [notes.sema](examples/plugins/notes.sema) | Sema | Search Markdown notes by name, heading and text | `exec = ["sema", "--no-llm", "plugins/notes.sema", "--"]`, `prefix = "n"`, `env = { NOTES_DIR = "~/Documents/Notes" }` |

Requirements: `calc.py` needs `python3` (macOS ships it with the Xcode command-line tools), `github-repos.ts` needs [Bun](https://bun.sh) and a logged-in [`gh`](https://cli.github.com), the Sema examples need [`sema`](https://sema-lang.com) (`brew install helgesverre/tap/sema-lang`).

All of them at once:

```sh
mkdir -p ~/.config/hl/plugins
cp docs/examples/plugins/* ~/.config/hl/plugins/
```

```toml
[[plugin]]
name = "Calc"
exec = "plugins/calc.py"
prefix = "="

[[plugin]]
name = "Processes"
exec = "plugins/processes.sh"
prefix = "ps"

[[plugin]]
name = "GitHub"
exec = "plugins/github-repos.ts"
prefix = "gh"

[[plugin]]
name = "Units"
exec = ["sema", "--no-llm", "plugins/units.sema", "--"]
prefix = "u"

[[plugin]]
name = "Hacker News"
exec = ["sema", "--no-llm", "plugins/hacker-news.sema", "--"]
prefix = "hn"
icon = "newspaper"

[[plugin]]
name = "Notes"
exec = ["sema", "--no-llm", "plugins/notes.sema", "--"]
prefix = "n"
icon = "note.text"
env = { NOTES_DIR = "~/Documents/Notes" }
```

## Writing plugins in Sema

[Sema](https://sema-lang.com) is a Lisp with HTTP, JSON, regex, files and shell built in, and it starts in a few milliseconds, which suits plugins that run on every keystroke.

**Run it through the list form of `exec`.** The `sema` command passes arguments to a script only after `--`, so a script can't be run directly with the query appended (`#!/usr/bin/env sema` plus an argument fails with "unexpected argument"). Use:

```toml
exec = ["sema", "--no-llm", "plugins/x.sema", "--"]
```

`--no-llm` skips Sema's LLM provider setup, which a plugin doesn't need. The launcher appends the query after `--`.

**Read the query** from the arguments after `--` (or from `(env "HL_QUERY")`):

```sema
(defn script-args ()
  (let loop ((xs (sys/args)))
    (cond ((null? xs) '())
          ((equal? (first xs) "--") (rest xs))
          (else (loop (rest xs))))))

(define query (string/join (script-args) " "))
```

**Print the result** with `json/encode`. Keyword keys become JSON keys, and vectors become arrays:

```sema
(println
  (json/encode
    {:items [{:title f"You typed ${query}"
              :icon "text.cursor"
              :actions [{:title "Copy" :copy query}]}]}))
```

A complete minimal plugin:

```sema
;; plugins/shout.sema: upper-cases the query; Enter pastes it.
(defn script-args ()
  (let loop ((xs (sys/args)))
    (cond ((null? xs) '())
          ((equal? (first xs) "--") (rest xs))
          (else (loop (rest xs))))))

(define query (string/join (script-args) " "))

(println
  (json/encode
    {:items (if (equal? query "")
              []
              [{:title (string/upper query)
                :actions [{:title "Paste" :paste (string/upper query)}]}])}))
```

Useful builtins (look any up with `sema doc <name>`, or search with `sema doc search "…"`):

| Need | Builtin |
|---|---|
| HTTP request | `(http/get url {:timeout 10000})` → `{:status … :body …}` |
| Parse JSON | `(json/decode string)` (object keys become keywords) |
| Run a command | `(shell "cmd")` → `{:stdout … :stderr … :exit-code …}` |
| Quote for `run` | `(shell/quote path)` |
| Files | `file/glob` (`**` recurses), `file/read`, `file/info`, `path/join` |
| Text | `string/lower`, `string/contains?`, `string/trim`, `regex/match`, `f"…${expr}…"` |
| Errors | `(try … (catch e (:message e)))` |

Format with `sema fmt plugins/x.sema`. The three Sema examples above show HTTP with error handling, file search with ranking, and query parsing with regexes.

## Tips

- Return `{"items": []}` for an empty query when there is nothing useful to show yet.
- Keep each run fast; it happens on every keystroke. Cache slow data in a file (for example under `$TMPDIR`) if needed.
- Build JSON with a real encoder (`json/encode`, `json.dumps`, `JSON.stringify`). The shell examples escape by hand only to avoid dependencies.
- Use `paste` for things you type into other apps (results, snippets), `copy` when you want to choose where they go.
