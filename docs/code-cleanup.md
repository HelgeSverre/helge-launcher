# Code cleanup

## Scope

| | |
|---|---|
| Repository | github.com/HelgeSverre/helge-launcher, package `HelgeLauncher` (executable) + `HelgeLauncherTests` |
| Baseline | `52c2f0d`, clean worktree, CI run 44380877708 green (tests, build, sign, notarize) |
| Included | `Sources/HelgeLauncher/*`, `Tests/HelgeLauncherTests/*`, `scripts/*`, docs that state behaviour |
| Excluded | `tools/icon.swift` (asset generator), `docs/examples/plugins/*` (verified separately), `.github/workflows/release.yml` (gate, not a target) |
| Toolchain | Swift 6.2.4 (Xcode 26.3), Swift 5 language mode, macOS 15.6 arm64; CI: macos-15 runner |

### Validation matrix

| Gate | Source | Command | Artifact | Baseline |
|---|---|---|---|---|
| G1 debug build | CI, justfile | `swift build` | `.build/debug/HelgeLauncher` | pass (sha256 `10cd6d12…`) |
| G2 tests | CI `Run tests`, justfile | `swift test` | test bundle, debug | pass, 13 tests |
| G3 release bundle | `scripts/bundle.sh` | `just bundle` | `build/Helge Launcher.app` (native, Developer ID signed) | pass |
| G4 universal signed | `scripts/release.sh --no-notarize` | `just package` | `dist/HelgeLauncher-<v>-universal.zip` | pass at 3a68570 |
| G5 headless plugins | docs/plugins.md | `HL_CONFIG_DIR=… --plugin <name>` for the 7 examples | debug binary | pass |
| G6 CI | `.github/workflows/release.yml` (workflow_dispatch) | tests + build + sign + notarize | runner artifact | pass (44380877708) |
| G7 TSan | added in this task | `swift test --sanitize=thread --disable-xctest` | debug + TSan | not run at baseline |

## Machine inventory

| ID | Machine | Owner | Representation | Entry points | Linked | Disposition |
|---|---|---|---|---|---|---|
| M1 | opencode server | `OpenCode` (AI.swift) | `process`, `baseURL`, `startTask`, detached SSE task (implicit) | `reloadConfig`, `createSession`, `stop` | M2 | changed |
| M2 | AI conversation | `Launcher` | `aiSession`, `chat[]`, in-flight `send` tasks, `OpenCode.handlers[sid]` | `askAI`, `submitAI`, `newChat`, SSE events | M1 | changed |
| M3 | Launcher mode / list / selection | `Launcher` | `mode`, `query`, `items`, `selected`, `showActions`, `actionIndex`, `pluginTask` | keys, `enter`, `back`, `hide`, `show`, prefix routing, plugin completion, 1Password completion | M5, M6 | changed |
| M4 | child process run | `Shell.run` | Process + 2 pipes + timeout work item + continuation | plugins, `op`, commands, plugin `run` actions | M3, M5 | changed |
| M5 | 1Password cache | `OnePassword` | `cached`, `loading`, `lastError`, `accountUUID` | `enter(.onepassword)`, `items`, secret copies | M3, M4 | changed |
| M6 | snippet use | `Snippets` + `Pasteboard` | async expand → copy/paste, panel hidden before await | snippet actions | M7, M5 | changed |
| M7 | clipboard history | `ClipboardHistory` | entries, `lastChange`, image files, poll timer | pasteboard poll, restore, pin, delete, trim | M6 | changed |
| M8 | config reload | `AppDelegate.reloadConfig` + `ConfigWatcher` | `hasGoodConfig`, watched files + mtimes | watcher tick, menu, command | M1, hotkeys | changed |
| M9 | hotkeys | `Hotkeys` | Carbon refs, id→action | `reloadConfig` | M8 | inspected, no defect (losing a taken hotkey on reload is reported) |
| M10 | Accessibility helper | `PermissionHelper` | timer, panel, `sawSettings`, start time | launch, menu, paste without trust | M6 | changed (menu refresh) |
| M11 | frecency | `History` | id → (count, last), JSON | actions, `enter` | M3 | changed (key) |
| M12 | panel visibility | `LauncherPanel` / `Launcher.hide/show` | window key/visible | hotkey, resignKey, URL scheme | M3 | changed (`show?q`) |

## Issues

| ID | Priority | Root cause / invariant | Reachable trace | Fix / batch | Status |
|---|---|---|---|---|---|
| I1 | high | M1 has no owner of the child lifetime: the child outlives the app, a dead child is never restarted, startup can hang, config changes are ignored, state is mutated from several threads | `pkill -x HelgeLauncher` leaves `opencode serve` running (12 orphans found on the dev Mac); kill the child → every AI request fails until relaunch; `opencode` that never prints a URL → "Thinking…" forever; `enabled = false` keeps the child | A1: actor with explicit state; `serve --stdio` with a held stdin pipe (child exits on our death); termination handler → idle; startup timeout races the read; `apply(config)` restarts/stops; owned SSE task | implemented f96694b; tests AITests.OpenCodeLifecycleTests (5); real opencode: --ai answers, SIGKILL of launcher → server exits ≤4 s; 12 orphans removed · Challenge pending |
| I2 | high | M2 events are routed per session, not per turn; session creation is check-then-await; `newChat` doesn't fence old work | send Q2 while Q1 streams → Q1's tail lands in Q2, Q1 never finishes; ⌘N during session creation → old answer streams into the new chat; two asks on cold start → two sessions | A1: conversation epoch + one in-flight creation task; one prompt in flight per conversation; handler removed on terminal event and on new chat | implemented f96694b; tests AITests.ConversationTests (5) · Challenge pending |
| I3 | high | M3 async results are applied without checking they still belong to the current mode/request; selection is by index | Esc while a plugin runs → plugin items replace root list, ↵ runs a plugin `run` action; results under an open ⌘K menu switch its item; Pin moves the highlight; click while ⌘K open runs the menu action on the clicked row; 1Password load resets selection | A2: mode setter cancels plugin work; request generation; one `setItems` that keeps selection by id and closes the menu when the item changes | implemented 52d0cf9; LauncherStateTests (8); baseline red by reviewer RaceRepro · Challenge pending |
| I4 | medium | M4 reads pipes sequentially, ignores cancellation, kills only the direct child | >64 KB stderr → false timeout; cancelled plugin query runs to completion; `cmd &` holding stdout blocks past the timeout | A3: concurrent pipe reads, cancellation handler, own process group killed on timeout/cancel, resume once | implemented c01dcc4; ShellRunTests (5) · Challenge pending |
| I5 | high (privacy) | M6 treats a 1Password secret like ordinary text and pastes after an unbounded await | `op://` snippet → secret saved in plaintext to clipboard.json and history; slow Touch ID → secret pasted into whichever app is in front later | A3: secret copies concealed + auto-cleared; paste only if the target app is still in front and the launcher wasn't reopened, else copy + notice | implemented c01dcc4; PasteboardTests.SnippetSecretTests (2) · Challenge pending |
| I6 | medium | M5 mutable state on a non-isolated class | TSan: `loading`/`cached` races between pool and main (reproduced by reviewer) | A3: `@MainActor` with one in-flight refresh task | implemented c01dcc4; OnePasswordTests (1); TSan clean (G7) vs 2 races at baseline · Challenge pending |
| I7 | medium | M8 watcher only learns include files from a successful load | add `include = ["x.toml"]` before creating it, or break an include → fixing it never reloads | A4: loader reports attempted files on failure too; watcher reset on every load | implemented 1e7c501; ConfigLoadTests (3) · Challenge pending |
| I8 | medium | M11 records modes under `"mode.\(Mode)"`, not the item id | plugins (`plugin:X`) never gain frecency | A2: record the activated item's id; prefix jump records the plugin id | implemented 52d0cf9; LauncherSelectionTests.enteringAPluginRecordsItsListId · Challenge pending |
| I9 | low | M7 images are keyed by a fresh UUID; delete doesn't remove the file; `max_items` unvalidated | same image copied 5× → 5 entries/files; deleted images leak on disk | A4: content-hash file names + dedupe; delete removes unreferenced file; clamp `max_items ≥ 1` | implemented 1e7c501; PasteboardTests.ClipboardImageTests (2) · Challenge pending |
| I10 | low | M10 menu item only refreshed at launch and from the helper | grant Accessibility after closing the helper → "Grant Accessibility…" stays | A4: refresh when the menu opens | implemented 1e7c501; manual (menuWillOpen) — no automated test · Challenge pending |
| I12 | medium | M8 the default config includes `snippets.toml`, which a new install doesn't have | fresh install → config error on first launch | A4: a missing include counts as empty and stays watched | implemented 1e7c501 (`ConfigLoadTests.missingConfigIsCreatedWithDefaults` found it) · Challenge pending |
| I11 | low (docs) | M12 `show?q=` keeps AI mode | last state AI chat → `helgelauncher://show?q=x` types into the chat | A2: `show?q` goes to root search | implemented 52d0cf9; LauncherSelectionTests.showWithAQueryLeavesTheAIChat · Challenge pending |

### Hypotheses (not confirmed)

| ID | Note |
|---|---|
| Hy1 | Duplicate item ids (same snippet name in two files, plugin duplicate ids) make `ForEach`/`scrollTo` unpredictable. Fold into I3 by de-duplicating ids in `setItems`. |
| Hy2 | `restore` within 0.5 s of another app's copy skips that copy in history. Rare; accepted. |
| Hy3 | Disabling then re-enabling clipboard history records whatever is on the pasteboard. Accepted (records the current item). |
| Hy4 | Two `copySecret` calls finishing out of order leave the earlier secret on the clipboard. Accepted. |

## Round log

| Round | Snapshot | Assignments | Result |
|---|---|---|---|
| A-Discover | 52c2f0d | lifecycle (AI, AppDelegate, PermissionHelper, Hotkeys) · concurrency (Launcher, Plugins, OnePassword, Shell, Snippets) · consumers (Clipboard, Config, Views, History, AppIndex, docs) | 21 confirmed findings → I1–I11; 3 reproduced by execution (plugin stale results, Shell.run a/b/c, OnePassword TSan) |
| A batches | f96694b, 52d0cf9, c01dcc4, 1e7c501 | coordinator implemented A1 (I1, I2), A2 (I3, I8, I11), A3 (I4, I5, I6), A4 (I7, I9, I10, I12) | G2: 44 tests pass ×3; G7 TSan clean on 18 concurrency tests |
