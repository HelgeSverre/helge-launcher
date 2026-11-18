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
| G2 tests | CI `Run tests`, justfile | `swift test` | test bundle, debug | baseline 13 pass; A8 62 pass ×3 |
| G3 release bundle | `scripts/bundle.sh` | `just bundle` | `build/Helge Launcher.app` (native, Developer ID signed) | pass |
| G4 universal signed | `scripts/release.sh --no-notarize` | `just package` | `dist/HelgeLauncher-<v>-universal.zip` | pass at 3a68570 |
| G5 headless plugins | docs/plugins.md | `HL_CONFIG_DIR=… --plugin <name>` for the 7 examples | debug binary | pass |
| G6 CI | `.github/workflows/release.yml` (workflow_dispatch) | tests + build + sign + notarize | runner artifact | pass (44380877708) |
| G7 TSan | added in this task | `swift test --sanitize=thread --disable-xctest --filter <concurrency suites>` | debug + TSan | baseline: 2 races (reviewer); 3351017: clean, 31 tests |

## Machine inventory

| ID | Machine | Owner | Representation | Entry points | Linked | Disposition |
|---|---|---|---|---|---|---|
| M1 | opencode server | `OpenCode` (AI.swift) | `State` idle / starting(id, task) / running(Server: process, stdin, url, events task); `handlers[sid]` with `accepted` date | `apply` (reloadConfig), `createSession`, `prompt`, process exit, event-stream (re)connect, `stop` (applicationWillTerminate), CLI `--ai` | M2 | changed |
| M2 | AI conversation | `Conversation` | `turns`, `epoch`, `session`, `creating` task; busy = last turn not done | `askAI`, `submitAI`, `newChat`, SSE events | M1 | changed |
| M3 | Launcher mode / list / selection | `Launcher` | `mode`, `query`, `items`, `selected`, `showActions`, `actionIndex`, `pluginTask` | keys, `enter`, `back`, `hide`, `show`, prefix routing, plugin completion, 1Password completion | M5, M6 | changed |
| M4 | child process run | `Shell.run` | Process + stdin/stdout/stderr pipes, readability handlers + `DispatchGroup` for the two outputs, `ResumeOnce` continuation, `LockedFlag` cancelled, timeout closure holding the process weakly; `Shell.spawn` fire-and-forget | plugins, `op`, commands, plugin `run` actions | M3, M5 | changed |
| M5 | 1Password cache | `OnePassword` (`@MainActor`) | `cached`, `cachedAt`, `refreshing` task, `lastError`, `accountUUID` | `enter(.onepassword)`, `items`, secret copies | M3, M4 | changed |
| M6 | snippet use | `Snippets` + `Pasteboard` | async expand → copy/paste, panel hidden before await | snippet actions | M7, M5 | changed |
| M7 | clipboard history | `ClipboardHistory` | entries, `lastChange`, content-hashed image files, poll timer, `loadedCleanly` (false for the session when the history couldn't be read, and while `clipboard.json.corrupt` or `.moving` exists) | pasteboard poll, restore, pin, delete, trim | M6 | changed |
| M8 | config reload | `AppDelegate.reloadConfig` + `ConfigWatcher` | `hasGoodConfig`, watched files + mtimes | watcher tick, menu, command | M1, hotkeys | changed |
| M9 | hotkeys | `Hotkeys` | Carbon refs, id→action | `reloadConfig` | M8 | inspected, no defect (losing a taken hotkey on reload is reported) |
| M10 | Accessibility helper | `PermissionHelper` | timer, panel, `sawSettings`, start time | launch, menu, paste without trust | M6 | changed (menu refresh) |
| M11 | frecency | `History` | id → (count, last), JSON | actions, `enter` | M3 | changed (key) |
| M12 | panel visibility | `LauncherPanel` / `Launcher.hide/show` | window key/visible | hotkey, resignKey, URL scheme | M3 | changed (`show?q`) |

## Issues

Status refers to the current head unless a revision is named. "Verified" = fix reviewed by a rotated reviewer and its regression passing at that revision.

| ID | Priority | Root cause / invariant | Reachable trace | Fix | Evidence | Status |
|---|---|---|---|---|---|---|
| I1 | high | M1 had no owner of the child lifetime | `pkill -x HelgeLauncher` left `opencode serve` running (12 orphans on the dev Mac); a dead child was never restarted; startup could hang; config changes were ignored | `OpenCode` main-actor owner, idle/starting/running; `serve --stdio` with a held stdin pipe; termination → idle; start task installs `.running` itself after checking the process is alive; startup timeout and cancellation terminate the child; `apply(config)` | OpenCodeLifecycleTests (9); real opencode: `--ai` answers, SIGKILL of launcher → server exits ≤4 s; mutation: joiner test 6/6, stop-during-start 3/3, exit-after-URL 3/5 (timing-dependent) | implemented 869ccd0; Verify 4 pending |
| I2 | high | M2 events routed per session; check-then-await session creation; no fence on new chat | Q2 while Q1 streams mixed answers; ⌘N during session creation leaked the old answer; cold-start double sessions | `Conversation`: epoch, shared creation task, one prompt in flight, per-turn application, release on terminal/reset; reconnect check finishes prompts accepted >2 s ago whose session is inactive | ConversationTests (5); `active` endpoint shape confirmed against real opencode | implemented 869ccd0; Verify 4 pending |
| I3 | high | M3 async results applied without checking ownership; selection by index | Esc during a slow plugin → plugin items in root, ↵ runs plugin `run`; ⌘K menu switched item; Pin moved highlight; click with menu open ran the menu action; Tab carried the menu into AI | `mode` didSet cancels plugin work; mode check on results; `items` private(set), only `setItems` (selection by id, menu closes on item change, unique ids) | LauncherSelectionTests + PluginStalenessTests (2); baseline red: reviewer RaceRepro | implemented 869ccd0; Verify 4 pending |
| I4 | medium | M4 sequential pipe reads, no cancellation, process retained until timeout | 300 KB stderr → false timeout; cancelled plugin query ran on; 100 quick runs held 200 descriptors | concurrent reads, resume-once, cancellation before/after launch, weak timeout capture, pipes closed on exit, `Shell.spawn` for fire-and-forget | ShellRunTests (8); fd test mutation 201→<50 | implemented 869ccd0; Verify 4 pending |
| I5 | high (privacy) | M6 treated 1Password secrets as ordinary text and pasted after an unbounded await | `op://` snippet secret saved to clipboard.json; slow approval → pasted into a later app | concealed copy + clear_after; `canPaste` requires the same frontmost app and no reopen (`showCount`) | PasteboardTests: secrets, plain copy, canPaste, clear_after 0 | implemented 869ccd0; Verify 4 pending |
| I6 | medium | M5 mutable state on a non-isolated class | TSan races on `loading`/`cached` at baseline | `@MainActor`, shared refresh task | OnePasswordTests (1); G7 TSan clean | verified c01dcc4 |
| I7 | medium | M8 watcher only learned files from a successful load; stamps taken after parsing | broken/missing include never reloaded after fixing; a save during load was missed | `Loaded.stamps` (taken before each read) on every load; watcher reset before the early return | ConfigLoadTests (3); watcher wiring reviewed, not unit-tested | implemented 869ccd0; Verify 4 pending |
| I8 | medium | M11 recorded modes under `"mode.\(Mode)"` | plugins never gained frecency | `Mode.itemID` shared by root items and `enter` | LauncherSelectionTests.enteringAPluginRecordsItsListId | verified 52d0cf9 |
| I9 | low | M7 images keyed by fresh UUIDs; delete leaked files; corrupt history deleted every image | same image ×5 → 5 files; deleted images stayed on disk | content-hash names, `remove` deletes unreferenced files, missing image on restore drops the entry, corrupt JSON moved aside, cleanup only in the app's poller | PasteboardTests: dedupe (mutation-checked), missing image, corrupt history across two launches, max_items | implemented 869ccd0; Verify 4 pending |
| I10 | low | M10 menu item refreshed only at launch/helper | "Grant Accessibility…" stayed after granting elsewhere | refresh on `menuWillOpen` | manual only | implemented 1e7c501, not unit-tested |
| I11 | low (docs) | M12 `show?q=` kept AI mode; URL `ai` ignored `enabled`; busy `ai?q=` dropped the question | | `show(query:)` → root; `openAIChat` gated; busy keeps the question | LauncherSelectionTests | implemented 869ccd0; Verify 4 pending |
| I12 | medium | M8 default config includes `snippets.toml`, absent on a new install | fresh install showed a config error, then (after A5) a permanent warning | missing include counts as empty with a warning; first launch writes an empty `snippets.toml` | ConfigLoadTests.missingConfigIsCreatedWithDefaults | implemented 869ccd0; Verify 4 pending |

### Hypotheses (not confirmed)

| ID | Note |
|---|---|
| Hy1 | Duplicate item ids: folded into I3 (`setItems` makes ids unique). |
| Hy5 | A prompt that failed or was interrupted while the event stream was down is reported as done by the reconnect check; deltas buffered at reconnect can be lost. Resuming from the last event id would replace the check; not verified that opencode supports resume. Accepted. |
| Hy6 | Including `config.toml` from itself duplicates its blocks (unique ids hide it in the list). Accepted. |
| Hy7 | `stop()`/SIGTERM grandchild cleanup relies on Foundation starting each child in its own process group (confirmed by probe and `timeoutAlsoEndsBackgroundedGrandchildren`). |
| Hy2 | `restore` within 0.5 s of another app's copy skips that copy in history. Rare; accepted. |
| Hy3 | Disabling then re-enabling clipboard history records whatever is on the pasteboard. Accepted (records the current item). |
| Hy4 | Two `copySecret` calls finishing out of order leave the earlier secret on the clipboard. Accepted. |

## Round log

| Round | Snapshot | Assignments | Result |
|---|---|---|---|
| A-Discover | 52c2f0d | lifecycle (AI, AppDelegate, PermissionHelper, Hotkeys) · concurrency (Launcher, Plugins, OnePassword, Shell, Snippets) · consumers (Clipboard, Config, Views, History, AppIndex, docs) | 21 confirmed findings → I1–I11; 3 reproduced by execution (plugin stale results, Shell.run a/b/c, OnePassword TSan) |
| A batches | f96694b, 52d0cf9, c01dcc4, 1e7c501 | coordinator implemented A1 (I1, I2), A2 (I3, I8, I11), A3 (I4, I5, I6), A4 (I7, I9, I10, I12) | G2: 44 tests pass ×3; G7 TSan clean on 18 concurrency tests |
| A-Challenge | ed91cf7 | AI fixes (reviewer 3) · Launcher/Shell/1P/snippets (reviewer 1) · model, config, clipboard, docs (reviewer 2) | 9 defects (start-path races, busy askAI dropped the question, cancel-before-launch, ⌘K→Tab, id suffix, test that couldn't fail, restore of missing image, doc drift) + 10 hypotheses → repaired in 3351017 |
| A-Verify 1 | 3351017 (delta from ed91cf7) | AI start path (reviewer 1) · Launcher/Shell/snippets/clipboard (reviewer 3) · config + cross-batch + docs (reviewer 2) | 3 defects: fresh-install warning, corrupt history deleted images, descriptor retention until timeout → repaired in be5177d; AI delta: no defects, 2 test gaps closed |
| A-Verify 2 | d54bdcf (delta from 3351017) | config/clipboard (reviewer 1) · AI reconnect + Launcher (reviewer 3) · Shell fd + document audit (reviewer 2) | corrupt-history protection lasted one launch (found twice); busy-question fix could jump into a plugin; document test counts/statuses/representations wrong → repaired in A7. AI reconnect, Shell fd fix, default snippets file: no defects |
| A-Verify 3 | 7cd7eab (delta from d54bdcf) | clipboard (reviewer 2) · askAI (reviewer 1) · Shell timeout + document (reviewer 3) | corrupt-history test changed the pasteboard and could delete real images under HL_DATA_DIR; interrupted set-aside unprotected; URL ask while busy from root lost the question; document I3/I4/M4/M7 wrong → repaired in A8. Shell timeout: no defects; closing read handles on exit removed as a crash risk |

