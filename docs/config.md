# Configuration

Everything is configured in `~/.config/hl/config.toml` ([TOML](https://toml.io)). The file is created with defaults on first launch. Open it with ⌘, in the launcher, **Edit Config…** in the menu-bar menu, or the "Edit Helge Launcher Config" command.

**Saving applies the change.** The launcher checks the file (and included files) every second. If the new version has an error, the previous working config keeps running and the error is shown in the launcher's footer and at the top of the menu-bar menu. Fix and save again.

`HL_CONFIG_DIR=/some/dir` makes the launcher use another directory instead of `~/.config/hl`, which is handy for trying things out (see [plugins.md](plugins.md#testing-a-plugin)).

## Complete example

Every option with its default, except where marked as an example:

```toml
hotkey = "cmd+space"            # opens and closes the launcher
launch_at_login = false
include = ["snippets.toml"]     # more files with [[snippet]], [[command]], [[plugin]] blocks

[ai]
enabled = true
model = "opencode-go/deepseek-v4.1-flash"
opencode = "opencode"           # the opencode binary
# system = "Answer in one short paragraph."     (example)

[clipboard]
enabled = true
max_items = 500
ignore_apps = ["com.1password.1password", "com.agilebits.onepassword7"]
# hotkey = "cmd+shift+v"        (example: open clipboard history directly)

[onepassword]
enabled = true
op = "op"
clear_after = 90
use_service_account = false
# account = "my.1password.com"  (example)

[cleanshot]
enabled = true

[[command]]                     # (example)
name = "Downloads"
open = "~/Downloads"
hotkey = "cmd+alt+d"

[[snippet]]                     # (example)
name = "email"
text = "helge@example.com"

[[plugin]]                      # (example)
name = "Calc"
exec = "plugins/calc.py"
prefix = "="
```

## Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `hotkey` | [hotkey](#hotkeys) | `"cmd+space"` | Toggles the launcher. Turn off Spotlight's ⌘Space first (System Settings → Keyboard → Keyboard Shortcuts → Spotlight). |
| `launch_at_login` | bool | `false` | Registers the app as a login item (System Settings → General → Login Items). |
| `include` | list of paths | `[]` | Extra TOML files, relative to the config directory or with `~`. Their `[[snippet]]`, `[[command]]` and `[[plugin]]` blocks are added to this file's; any other settings in them are ignored. A file that doesn't exist yet counts as empty (the footer notes "include … not found") and is picked up when you create it. |

## `[ai]`

AI answers through a local [opencode](https://opencode.ai) server. See [ai.md](ai.md).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Shows "Ask AI" and the AI Chat command, and starts `opencode serve` in the background |
| `model` | string | `"opencode-go/deepseek-v4.1-flash"` | `provider/model`, as listed by `opencode models` |
| `opencode` | string | `"opencode"` | The opencode binary: a name looked up on your shell's `PATH`, or a path (`~` works) |
| `system` | string | none | Text sent before every question, for standing instructions |

## `[clipboard]`

Clipboard history: text, links, colours (`#rrggbb`), files and images.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Records the clipboard and shows the Clipboard History command |
| `max_items` | int | `500` | Unpinned entries kept (at least 1); older ones are dropped. Pinned entries are always kept. |
| `ignore_apps` | list of bundle IDs | 1Password 7 and 8 | Copies made while one of these apps is in front are not recorded |
| `hotkey` | [hotkey](#hotkeys) | none | Opens clipboard history directly |

Copies that the source app marks as concealed or transient (password managers do this; the [nspasteboard.org](http://nspasteboard.org) convention) are never recorded. Find an app's bundle ID with `osascript -e 'id of app "Slack"'`.

In clipboard history: ↵ pastes, ⌘↵ copies, ⌘K also has Pin/Unpin and Delete. History is stored in `~/Library/Application Support/HelgeLauncher/clipboard.json` (images next to it).

## `[onepassword]`

Search 1Password items and copy passwords, usernames and one-time codes, through the [`op` CLI](https://developer.1password.com/docs/cli/).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Shows the 1Password command |
| `op` | string | `"op"` | The `op` binary |
| `account` | string | none | Passed as `--account` when you have several 1Password accounts (`my.1password.com`, an account ID, or a sign-in address) |
| `clear_after` | int (seconds) | `90` | Copied secrets are removed from the clipboard after this long, if the clipboard still holds them. `0` never clears. |
| `use_service_account` | bool | `false` | `false`: `op` uses the 1Password app (your own vaults), and an `OP_SERVICE_ACCOUNT_TOKEN` in the environment is ignored. `true`: the token is used. |

Setup: in 1Password, enable **Settings → Developer → Integrate with 1Password CLI**. The first search asks you to approve access in 1Password. Items are cached for 5 minutes.

Actions on an item: Copy Password (or Credential for API credentials), Copy Username, Copy One-Time Password, Open in 1Password, Open Website. Copied secrets are marked concealed, so clipboard managers (including this one) skip them.

## `[cleanshot]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Adds CleanShot X commands (Capture Area, Record Screen, Capture Text (OCR), Restore Recently Closed, …) using its `cleanshot://` URL scheme |

The commands need [CleanShot X](https://cleanshot.com). CleanShot's own global shortcuts (set in CleanShot's settings) keep working independently.

## `[[command]]`

Your own commands: open something or run a shell command, from the search or a global hotkey.

```toml
[[command]]
name = "Downloads"
open = "~/Downloads"

[[command]]
name = "Lock Screen"
run = "pmset displaysleepnow"
hotkey = "ctrl+cmd+l"
keywords = ["sleep", "away"]
icon = "lock"
```

| Key | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Title in the search |
| `open` | string | one of `open`/`run` | A URL, file, folder or app path (`~` works) |
| `run` | string | one of `open`/`run` | Shell command, run with `zsh -lc` in the background (output is discarded) |
| `hotkey` | [hotkey](#hotkeys) | no | Global shortcut that runs the command without opening the launcher |
| `keywords` | list of strings | no | Extra words the search matches |
| `icon` | string | no | SF Symbol name or an emoji. Default: a link or terminal symbol. |

When both `open` and `run` are set, both happen.

## `[[snippet]]`

Text to paste, with placeholders such as `{date}` and `{clipboard}` and optional 1Password references. See [snippets.md](snippets.md).

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Title and search term |
| `text` | yes | The text |
| `keyword` | no | Extra search term |

## `[[plugin]]`

External programs that provide their own list. See [plugins.md](plugins.md).

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Title in the search |
| `exec` | yes | Path, or list of program and arguments |
| `prefix` | no | Typing it plus a space jumps into the plugin |
| `icon` | no | SF Symbol, emoji or image path |
| `env` | no | Extra environment variables |

## Hotkeys

Written as modifiers and one key joined by `+`, case-insensitive: `"cmd+space"`, `"alt+shift+k"`, `"f13"`, `"hyper+t"`.

| Modifiers | Also accepted |
|---|---|
| `cmd` | `command`, `⌘` |
| `shift` | `⇧` |
| `alt` | `opt`, `option`, `⌥` |
| `ctrl` | `control`, `⌃` |
| `hyper` | all four at once |

| Keys | |
|---|---|
| Letters and digits | `a`–`z`, `0`–`9` |
| Punctuation | `` ` `` `-` `=` `[` `]` `\` `;` `'` `,` `.` `/` |
| Named | `space`, `return`, `tab`, `escape`, `delete`, `left`, `right`, `up`, `down` |
| Function keys | `f1`–`f20` |

A hotkey that another app already owns can't be registered; the launcher then shows "… is already in use" as a config error. Plain function keys work too (`"f12"`), unless another app already owns them, such as CleanShot's own capture shortcuts.

## Files

| Path | Contents |
|---|---|
| `~/.config/hl/config.toml` | This configuration |
| `~/.config/hl/snippets.toml` | Snippets (included by default) |
| `~/.config/hl/plugins/` | Conventional place for plugin scripts |
| `~/Library/Application Support/HelgeLauncher/history.json` | Launch counts used for ranking |
| `~/Library/Application Support/HelgeLauncher/clipboard.json` | Clipboard history (`clipboard-images/` beside it) |
| `~/Library/Application Support/HelgeLauncher/ai/` | Working directory of the opencode server |

`brew uninstall --zap --cask helge-launcher` removes the app, the config directory and all of these.
