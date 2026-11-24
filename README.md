# Helge Launcher

<img src="assets/AppIcon.png" width="128" alt="Helge Launcher icon">

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-facc15) ![MIT](https://img.shields.io/badge/license-MIT-facc15)

A keyboard launcher for macOS, written in Swift. It opens apps, runs CleanShot X captures, keeps clipboard history, pastes snippets and emoji, copies 1Password secrets and answers questions through [opencode](https://opencode.ai). It is configured in one TOML file and extended with plugins in any language.

## Install

```sh
brew install --cask helgesverre/tap/helge-launcher
```

Signed with Developer ID and notarized; macOS 14 or later.

1. Turn off Spotlight's ⌘Space (System Settings → Keyboard → Keyboard Shortcuts → Spotlight), or set another `hotkey` in the config.
2. Open Helge Launcher. A magnifier appears in the menu bar.
3. When asked, drag the app into the Accessibility list. The launcher opens System Settings and pins its icon under the window for this; it's needed to paste into other apps.

## What it does

| Feature | How |
|---|---|
| Apps | Type part of the name. Results rank by how often and how recently you open things. |
| Calculator | Type a sum, a conversion or a date question: `1.5 l per day for a year at 2 kr/ml in usd`, `5pm PST in Oslo` ([calculator.md](docs/calculator.md)) |
| CleanShot X | Capture Area, Record Screen, Capture Text (OCR), Restore Recently Closed and more |
| Clipboard history | "Clipboard History": text, links, colours, files and images; pin entries you keep |
| Snippets | Saved text with placeholders such as `{date}` and `{clipboard}`, or `op://` 1Password references ([snippets.md](docs/snippets.md)) |
| Emoji | "Search Emoji & Symbols" |
| 1Password | "1Password": search items, copy password, username or one-time code (via the `op` CLI) |
| AI | Tab sends what you typed to the AI; follow-ups continue the chat ([ai.md](docs/ai.md)) |
| Usage statistics | "Usage Statistics": launches in total, today and this week, the split by kind, and every app and command ranked by use. ↵ opens one; ⌘K → Forget resets its count. |
| Commands | Your own: open a URL, file or app, or run a shell command; optional global hotkey |
| Plugins | Any program that prints JSON adds its own list: calculators, repo search, notes… ([plugins.md](docs/plugins.md)) |

## Keys

| Key | Action |
|---|---|
| ⌘Space | Open or close (config `hotkey`) |
| ↑ ↓ | Select |
| ↵ | Run the selected item's first action, or open it |
| ⌘↵ | Second action (for example Copy instead of Paste) |
| ⌘K | All actions for the selected item |
| Tab | Ask the AI with what you typed |
| Esc, or ⌫ on an empty field | Back, then close |
| ⌘N | New AI chat |
| ↵ on an empty AI field | Copy the last answer |
| ⌘, | Edit the config |
| ⌘W | Close |
| ⌘A ⌘C ⌘V ⌘X ⌘Z | Text editing in the search field |

## Configuration

`~/.config/hl/config.toml`, applied on save:

```toml
hotkey = "cmd+space"
launch_at_login = true
include = ["snippets.toml"]

[ai]
model = "opencode-go/deepseek-v4.1-flash"

[[command]]
name = "Downloads"
open = "~/Downloads"
hotkey = "cmd+alt+d"

[[snippet]]
name = "stamp"
text = "{date:yyyyMMdd-HHmmss}"

[[plugin]]
name = "Units"
exec = ["sema", "--no-llm", "plugins/units.sema", "--"]
prefix = "u"
```

## Documentation

| | |
|---|---|
| [docs/config.md](docs/config.md) | Every option: hotkeys, clipboard, 1Password, CleanShot, commands, files on disk |
| [docs/snippets.md](docs/snippets.md) | Snippets, all placeholders, custom date formats, 1Password references |
| [docs/plugins.md](docs/plugins.md) | Writing plugins: protocol, testing, examples in sh, Python, Bun and Sema |
| [docs/ai.md](docs/ai.md) | The opencode integration, permissions, troubleshooting |
| [docs/releasing.md](docs/releasing.md) | Signing, notarization, Homebrew releases |

## URL scheme

Open the launcher from scripts, Shortcuts or other apps:

| URL | Opens |
|---|---|
| `helgelauncher://show` | The launcher (`?q=text` pre-fills the search) |
| `helgelauncher://clipboard` | Clipboard history |
| `helgelauncher://emoji` | Emoji search |
| `helgelauncher://snippets` | Snippet search |
| `helgelauncher://1password` | 1Password search |
| `helgelauncher://stats` | Usage statistics |
| `helgelauncher://ai?q=question` | AI chat, asking the question (without `q`: the chat) |

```sh
open 'helgelauncher://ai?q=What%20is%20my%20IP%20used%20for'
```

## Command line

The app binary also runs without the UI, for scripting and testing:

```sh
HL=/Applications/Helge\ Launcher.app/Contents/MacOS/HelgeLauncher
"$HL" --search "tab"                       # ranked results
"$HL" --mode emoji --search "thumbs"       # modes: root, emoji, snippets, clipboard, onepassword
"$HL" --plugin Units --search "10 km in mi"
"$HL" --expand 'Week {date:ww}'
"$HL" --ai "One sentence on what opencode is"
```

`HL_CONFIG_DIR=/path` uses another config directory.

## Development

```sh
just            # list recipes
just test       # test suite
just install    # build and install a development copy in /Applications
just release    # universal, signed, notarized ZIP in dist/
```

Swift 6 toolchain (Xcode 16 or later). Development builds are signed with the Developer ID when one is in the Keychain, so the Accessibility grant survives rebuilds.

The icons are drawn by `tools/icon.swift` (`just icons`) in the same style as [Helge Terminal](https://github.com/HelgeSverre/terminal): dark tile, thin rim, a yellow magnifier whose square-cut handle matches the terminal's cursor bar.

## License

MIT, see [LICENSE](LICENSE).
