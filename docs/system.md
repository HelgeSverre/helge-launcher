# Processes, ports, leftovers and storage

Four commands in the main search replace most trips to Activity Monitor, `lsof`, `pkill` and `du`. The process commands sample every 2 seconds while open and stop when you leave them.

## Processes

Every running process, grouped: an app with all its helpers (Google Chrome ×28), otherwise by executable name (node ×69). Above the list: CPU per core, memory with pressure and swap, free disk space, battery.

| Key | Action |
|---|---|
| ↵ | Quit the group (apps through AppKit, so they can ask to save; other processes get SIGTERM) |
| ⌘↵ | Force quit (SIGKILL) |
| → / ← | List or close the group's processes, with command line, folder, ports and age |
| Tab | Sort by CPU, Memory, Disk or Network |
| ⌘L | Leftover dev processes |
| ⌘K | Show Ports, Sample for 3 Seconds, Copy PIDs, Open Activity Monitor; on a process also Open Folder, Open localhost, Copy Command Line |

Processes of other users (root daemons, WindowServer) show CPU and resident memory from `ps`; quitting one asks for your password. macOS's own essentials (kernel_task, launchd, WindowServer, loginwindow) can't be quit from here.

## Ports

Every TCP port a process of yours listens on: your dev servers (with the command that started them, such as `bun run dev`, and their folder), services (Herd, DBngin, mailpit, apps) and macOS (AirPlay Receiver on 5000 and 7000). Apps' temporary ports above 49151 are left out. ↵ opens `http://localhost:<port>`, ⌘↵ stops the server.

The main search answers port questions directly: `5173`, `:5173`, `port 5173` or `localhost:5173` shows what listens there, or "Nothing is listening on :3000" (a bare number only answers when something listens).

## Leftover dev processes

Dev tools whose terminal, editor or agent session closed without stopping them, typically MCP servers and `npm`/`bun` processes. A process is a leftover when all of these hold:

- it is yours and its parent is launchd (the process that started it is gone),
- it is not a launchd job (`launchctl list`: brew services and app agents are left alone),
- it is not inside an `.app` bundle,
- it is a dev runtime (node, npm, bun, deno, python, uv, ruby, …) or calls itself an MCP server.

Everything a leftover started counts with it. Leftovers that still listen on a port are listed separately as "Still serving a port", since that is often a dev server you left running on purpose. ↵ quits one group, ⌘↵ all leftovers that aren't serving. The processes list shows a banner when there are any, and typing a leftover's name in the main search offers to quit it.

## Storage

Free space on the startup disk (as Finder counts it) and the size of folders that tend to grow: Android SDK, Downloads, `~/.cache`, `~/Library/Caches`, Xcode DerivedData, iOS Simulators, OrbStack, and the npm, Bun, pnpm, Gradle and Cargo caches. Sizes come from `du`, run in the background and remembered between launches; ⌘K → Measure Again refreshes one.

⌘↵ clears a folder that is safe to clear: press it twice within 4 seconds. Caches are emptied; Simulators, OrbStack, npm, Bun and pnpm use their own cleanup command (`xcrun simctl delete unavailable`, `docker system prune -f`, `npm cache clean --force`, `bun pm cache rm`, `pnpm store prune`). Downloads, the Android SDK and Ollama models are only shown, for you to review in Finder.

## Running apps in the main search

A running app's row shows its CPU and memory, and a "Quit <app>" row follows the first one (⌘↵ force quits).
