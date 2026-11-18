# Snippets

A snippet is named text you paste often: an address, a signature, a license header, a command. Snippets show up in the main search and under **Search Snippets**.

| Key | Does |
|---|---|
| ↵ | Paste into the app you were in |
| ⌘↵ | Copy to the clipboard |

Pasting needs Accessibility permission (see the README). Without it the text is still copied, so ⌘V works by hand.

## Defining snippets

Add `[[snippet]]` blocks to `~/.config/hl/config.toml`, or to a file it includes (the default config includes `snippets.toml`):

```toml
[[snippet]]
name = "email"
text = "helge@example.com"

[[snippet]]
name = "mit"
keyword = "license"          # optional: an extra word the search matches
text = "MIT License, Copyright (c) {date:yyyy} Helge Sverre"
```

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | What you search for, and the title in the list |
| `text` | yes | The text to paste. May contain [placeholders](#placeholders) or be a [1Password reference](#1password-references). |
| `keyword` | no | Another term the search matches, in addition to the name |

The config reloads on save; new snippets appear immediately.

### Multi-line text

Use TOML's triple quotes. A newline directly after the opening `"""` is dropped; everything else is kept as written:

```toml
[[snippet]]
name = "standup"
text = """
Yesterday: {clipboard}
Today:
Blockers: none
"""
```

Use `'''…'''` (literal strings) when the text contains backslashes you don't want TOML to interpret, such as regexes or Windows paths.

## Placeholders

Placeholders are replaced every time the snippet is used, with the current date, time and clipboard.

| Placeholder | Becomes | Example output |
|---|---|---|
| `{date}` | Today | `2026-11-18` |
| `{time}` | Current time, 24-hour | `14:05` |
| `{datetime}` | Date and time | `2026-11-18 14:05` |
| `{iso}` | ISO 8601 timestamp with time-zone offset | `2026-11-18T14:05:09+01:00` |
| `{weekday}` | Day name, English | `Wednesday` |
| `{timestamp}` | Unix time in seconds | `1795010709` |
| `{date:FORMAT}` | Date and/or time in your own format (below) | `{date:dd.MM.yyyy}` → `18.11.2026` |
| `{uuid}` | A new random UUID, lowercase, different each time | `70ff9628-39a8-47d8-9c00-30a25f29f3d2` |
| `{clipboard}` | The text currently on the clipboard (empty if it holds no text) | |

Times use your Mac's time zone. Day and month names are English.

Anything else in braces is left exactly as written: `{name}`, `{DATE}` and `{` on its own are pasted unchanged, so JSON, code and templates with braces are safe.

### Custom formats

`{date:FORMAT}` takes a [Unicode date pattern](https://www.unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table), the same one macOS uses. The most useful symbols:

| Symbol | Meaning | Example |
|---|---|---|
| `yyyy` | Year | `2026` |
| `MM` / `M` | Month, padded / not | `11` / `11` |
| `MMM` / `MMMM` | Month name, short / full | `Nov` / `November` |
| `dd` / `d` | Day of month, padded / not | `08` / `8` |
| `EEE` / `EEEE` | Weekday, short / full | `Wed` / `Wednesday` |
| `HH` | Hour, 00–23 | `14` |
| `hh` + `a` | Hour, 01–12, and AM/PM | `02 PM` |
| `mm` | Minute | `05` |
| `ss` | Second | `09` |
| `ww` | Week of year | `47` |
| `Z` | Time-zone offset | `+0100` |
| `'text'` | Literal text | `'week' ww` → `week 47` |

Examples:

```toml
[[snippet]]
name = "norwegian date"
text = "{date:dd.MM.yyyy}"                # 18.11.2026

[[snippet]]
name = "log heading"
text = "## {date:EEEE d MMMM} ({date:'week' ww})"   # ## Wednesday 18 November (week 47)

[[snippet]]
name = "file stamp"
text = "{date:yyyyMMdd-HHmmss}"           # 20261118-140509
```

The format can't contain `}`.

## 1Password references

When the **entire** `text` is one `op://` reference, the value is read from 1Password at the moment you use the snippet. The secret is never written to the config:

```toml
[[snippet]]
name = "OpenAI key"
text = "op://Personal/OpenAI/credential"
```

- The format is `op://<vault>/<item>/<field>`, or `op://<vault>/<item>/<section>/<field>` for a field inside a section. In 1Password, right-click a field and choose **Copy Secret Reference** to get it exactly.
- It is read with the [`op` CLI](https://developer.1password.com/docs/cli/) through the 1Password app, which may ask you to approve access.
- The list shows the reference, never the value, and there is no preview for it.
- It must be the whole text on one line. `op://` inside a longer text is pasted literally.
- Placeholders are expanded first, so a reference can include one (rarely useful).
- The value is copied as concealed, so clipboard history (this app's and other managers') skips it, and it is cleared from the clipboard after `clear_after` seconds (90 by default, see [config.md](config.md#onepassword)).
- If you switch apps or reopen the launcher while 1Password asks for approval, the value is copied instead of pasted, so it never lands in the wrong app.
- If 1Password can't be read (locked, approval declined or not answered within 30 seconds), nothing is pasted or copied.

`op` runs through the 1Password desktop app integration (enable **Settings → Developer → Integrate with 1Password CLI** in 1Password). An `OP_SERVICE_ACCOUNT_TOKEN` in your environment is ignored unless `use_service_account = true` is set under `[onepassword]`; see [config.md](config.md#onepassword).

## Testing a snippet

Expand a text exactly as a paste would, without opening the launcher:

```sh
HelgeLauncher --expand 'Today is {weekday} {date:d MMMM}'
# Today is Wednesday 18 November

HelgeLauncher --expand 'op://Personal/OpenAI/credential'   # prints the secret: only in a private terminal
```

`HelgeLauncher` is `/Applications/Helge Launcher.app/Contents/MacOS/HelgeLauncher`. From the repository: `just expand '…'`.

## Organizing

- Keep snippets in their own file and include it: `include = ["snippets.toml"]` in `config.toml`. Included files may contain only `[[snippet]]`, `[[command]]` and `[[plugin]]` blocks; their other settings are ignored.
- The 15 snippets imported from Raycast are in `~/.config/hl/snippets.toml`.
- Snippets are ranked by how often and how recently you use them, like everything else in the search.
