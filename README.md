# Helge Launcher

<img src="assets/AppIcon.png" width="128" alt="Helge Launcher icon">

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-facc15) ![MIT](https://img.shields.io/badge/license-MIT-facc15)

A small macOS launcher (Swift, AppKit + SwiftUI) that replaces the parts of Raycast that get used: apps, CleanShot, clipboard history, snippets, emoji, 1Password and AI through `opencode serve`.

## Install

```sh
brew install --cask helgesverre/tap/helge-launcher
```

Signed with Developer ID and notarized. Releases: [docs/releasing.md](docs/releasing.md).

## Build

```sh
just build      # debug
just bundle     # build/Helge Launcher.app (Developer ID signed when available)
just install    # copy the dev build to /Applications and start
just release    # universal, signed, notarized ZIP in dist/
just search tp  # headless ranked search
just ask "…"    # headless AI question
```

## Keys

| Key | Action |
|---|---|
| ⌘Space (config `hotkey`) | toggle panel |
| ↵ / ⌘↵ | primary / secondary action |
| ⌘K | all actions for the selected item |
| Tab | ask AI with the current query |
| Esc, ⌫ on empty | back / close |
| ⌘N (AI) | new chat |
| ↵ on empty (AI) | copy last answer |
| ⌘, | edit config |
| ⌘A ⌘C ⌘V ⌘X ⌘Z | text editing in the search field |

## Config

`~/.config/hl/config.toml`, reloaded on save. `include` merges more files (`snippets.toml` holds the snippets imported from Raycast).

```toml
hotkey = "cmd+space"
launch_at_login = true
include = ["snippets.toml"]

[ai]
model = "opencode-go/deepseek-v4.1-flash"   # provider/model as listed by `opencode models`
opencode = "opencode"                        # binary; PATH comes from your interactive zsh
# system = "Answer briefly."

[clipboard]
max_items = 500
hotkey = "cmd+shift+v"
ignore_apps = ["com.1password.1password"]

[onepassword]
clear_after = 90              # seconds before a copied secret is cleared
use_service_account = false   # false: drop OP_SERVICE_ACCOUNT_TOKEN, use the desktop-app integration
# account = "my.1password.com"

[cleanshot]
enabled = true

[[command]]
name = "Flush DNS"
run = "sudo -n dscacheutil -flushcache"   # or open = "<URL, app or file path>"; optional hotkey = "cmd+alt+d"

[[snippet]]
name = "date"
text = "Today is {date}"      # placeholders and 1Password references: see Snippets below

[[plugin]]
name = "Example"
exec = "plugins/example.sh"   # relative to ~/.config/hl
prefix = "ex"
```

## Snippets

Snippets appear in the main search and under **Search Snippets**. ↵ pastes into the app you were in, ⌘↵ copies.

```toml
[[snippet]]
name = "standup"
keyword = "su"                # optional extra search term
text = """
Yesterday: {clipboard}
Today ({date}):
"""
```

Placeholders are replaced each time the snippet is used:

| Placeholder | Becomes | Example |
|---|---|---|
| `{date}` | today, `yyyy-MM-dd` | `2026-11-18` |
| `{time}` | now, `HH:mm` (24 h) | `14:05` |
| `{clipboard}` | the current clipboard text | |

Text without placeholders is pasted as written. Use TOML `"""…"""` for multi-line text.

**1Password references.** When the whole `text` is a single `op://vault/item/field` reference, the value is read from 1Password with `op read` at the moment you paste, so the secret is never stored in the config:

```toml
[[snippet]]
name = "OpenAI key"
text = "op://Personal/OpenAI/credential"
```

- Copy a reference from 1Password with **Copy Secret Reference** on a field, or write it as vault / item / field name.
- The list shows the reference, never the value.
- It works only when the reference is the entire text (one line); `op://` inside a longer text is pasted literally.
- If `op` fails (locked, approval declined), nothing is pasted.

## Plugins

A plugin is any executable. It is called as `<exec> <query>` (also `$HL_QUERY`) on every keystroke (debounced) and prints:

```json
{"items": [{"title": "Deploy site", "subtitle": "ploi", "icon": "paperplane",
            "actions": [{"title": "Open", "open": "https://…"},
                        {"title": "Copy ID", "copy": "123"},
                        {"title": "Paste", "paste": "…"},
                        {"title": "Run", "run": "shell command"}]}]}
```

`icon` is an SF Symbol name, an emoji or a file path.

## URL scheme

`helgelauncher://show?q=…`, `://clipboard`, `://emoji`, `://snippets`, `://1password`, `://ai?q=…`

## Data

- `~/Library/Application Support/HelgeLauncher/history.json`: launch counts for ranking (seeded from Raycast's activity log)
- `…/clipboard.json`, `…/clipboard-images/`: clipboard history
- `…/ai/`: working directory of the opencode server (sessions deny every tool except webfetch/websearch)

Pasting (snippets, emoji, clipboard) sends ⌘V and needs Accessibility permission. Without it, the launcher opens System Settings → Accessibility and pins a panel with its icon under the Settings window; drag the icon into the list. The panel closes when the permission is granted. It also opens from the menu-bar item (Grant Accessibility…) and on the first paste attempt without permission. Builds signed with the Developer ID keep the grant across rebuilds and updates.

## Icon

`assets/AppIcon.png` and the menu-bar glyph in `Resources/` are drawn by `tools/icon.swift`, in the same style as Helge Terminal: dark tile, thin rim, `#FCD001` glyph. The glyph is a magnifier drawn with the terminal's stroke weight; its square-cut handle matches the terminal's cursor bar.

```sh
swift tools/icon.swift magnifier assets/AppIcon.png 1024
swift tools/icon.swift template Resources/MenuBarIcon@2x.png 44
swift tools/icon.swift template Resources/MenuBarIcon.png 22
```

## License

MIT, see [LICENSE](LICENSE).
