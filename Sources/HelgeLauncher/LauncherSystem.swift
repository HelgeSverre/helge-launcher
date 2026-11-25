import AppKit

/// What a process, port or storage row shows besides its title and subtitle.
enum SystemRow {
    /// An app or executable with all its processes.
    case group(count: Int, cpu: Double, memory: UInt64, disk: Double, network: Double, share: Double, sort: ProcSort)
    /// One process of the open group.
    case process(cwd: String?, ports: [Int], age: String, cpu: Double, memory: UInt64, sort: ProcSort)
    /// A leftover dev tool, or one of them that still serves a port.
    case leftover(count: Int, age: String, memory: UInt64, ports: [Int])
    /// A listening process in the Ports list.
    case port(ports: [Int], folder: String?, age: String)
    /// The main search's answer to "5173": what listens there, or nothing.
    case portAnswer(port: Int, facts: String?, folder: String?)
    /// A folder in Storage.
    case storage(path: String, bytes: Int64?, share: Double, tag: String)
}

/// Processes macOS can't run without.
private let essential: Set<String> = [
    "kernel_task", "launchd", "WindowServer", "loginwindow", "logd", "opendirectoryd",
]

extension Launcher {
    // MARK: Sampling

    /// Samples every 2 s while a process mode is open.
    func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snap = await SystemSampler.shared.sample(network: self.procSort == .network)
                guard !Task.isCancelled, self.mode.samplesProcesses else { return }
                self.snapshot = snap
                self.setItems(self.computeItems(), keepSelection: true)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    /// One sample in the background when the last one is older than `maxAge`, then a refresh of the
    /// main search (running apps, port answers, leftovers).
    func sampleIfStale(maxAge: TimeInterval = 10) {
        guard !Paths.isTestRunner, samplingTask == nil else { return }
        if let s = snapshot, Date().timeIntervalSince(s.date) < maxAge { return }
        samplingTask = Task { [weak self] in
            let snap = await SystemSampler.shared.sample()
            guard let self else { return }
            self.snapshot = snap
            if !self.mode.samplesProcesses { self.samplingTask = nil }
            if self.mode == .root && !self.query.isEmpty { self.setItems(self.computeItems(), keepSelection: true) }
        }
    }

    func cycleSort() {
        procSort = procSort.next
        refresh()
        if procSort == .network { startSampling() }
    }

    /// →: lists the selected group's processes. Returns false when there is nothing to open.
    func expandSelected() -> Bool {
        guard mode == .processes, let it = current, it.id.hasPrefix("group:") else { return false }
        let key = String(it.id.dropFirst(6))
        expandedGroup = expandedGroup == key ? nil : key
        setItems(computeItems(), keepSelection: true)
        return true
    }

    /// ←: closes the open group and selects it.
    func collapseGroup() -> Bool {
        guard mode == .processes, let key = expandedGroup else { return false }
        expandedGroup = nil
        setItems(computeItems(), keepSelection: false)
        if let i = items.firstIndex(where: { $0.id == "group:" + key }) { selected = i }
        return true
    }

    // MARK: Processes

    func processItems() -> [Item] {
        guard let s = snapshot else { return [] }
        var groups = ProcModel.groups(s.procs, sort: procSort)
        let lq = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !lq.isEmpty {
            // Groups named like the query first, in sort order within each half.
            let named = groups.filter { $0.title.lowercased().contains(lq) }
            groups = named + groups.filter { !$0.title.lowercased().contains(lq) }
        }
        let top = max(groups.first?.value(procSort) ?? 1, 0.000_001)
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []
        for g in groups {
            var it = Item(
                id: "group:" + g.key,
                title: g.title,
                subtitle: g.isSystem ? "macOS" : "",
                icon: g.appPath.map { .file($0) } ?? .symbol(g.isSystem ? "gearshape" : "terminal"),
                keywords: Array(
                    Set(
                        g.procs.flatMap { p in
                            [p.name, ProcModel.shortCommand(p, words: 2)]
                                + (p.cwd.map { $0 == "/" ? [] : [($0 as NSString).lastPathComponent] } ?? [])
                        }
                    )
                ),
                actions: groupActions(g)
            )
            it.system = .group(
                count: g.procs.count,
                cpu: g.cpu,
                memory: g.memory,
                disk: g.disk,
                network: g.network,
                share: min(1, g.value(procSort) / top),
                sort: procSort
            )
            if !q.isEmpty && !Launcher.matches(q, it) { continue }
            out.append(it)
            if expandedGroup == g.key {
                for p in g.procs.sorted(by: { procSort.value($0) > procSort.value($1) }).prefix(60) {
                    var c = Item(
                        id: "proc:\(p.pid)",
                        title: ProcModel.shortCommand(p, words: 6),
                        actions: processActions(p)
                    )
                    c.system = .process(
                        cwd: p.cwd.flatMap { $0 == "/" ? nil : Fmt.home($0) },
                        ports: p.ports,
                        age: Fmt.age(s.date.timeIntervalSince(p.started)),
                        cpu: p.cpu,
                        memory: p.memory,
                        sort: procSort
                    )
                    out.append(c)
                }
            }
        }
        return out
    }

    /// The title fuzzily, or a keyword (process name, short command, folder) containing the query.
    static func matches(_ q: String, _ it: Item) -> Bool {
        let lq = q.lowercased()
        return Fuzzy.score(q, it.title) != nil || it.keywords.contains { $0.lowercased().contains(lq) }
    }

    private func groupActions(_ g: ProcGroup) -> [Action] {
        var a = [
            Action(title: "Quit") { [weak self] in
                self?.quit(g.procs, app: g.appPath, name: g.title, force: false)
                return .stay
            },
            Action(title: "Force Quit") { [weak self] in
                self?.quit(g.procs, app: g.appPath, name: g.title, force: true)
                return .stay
            },
        ]
        if g.procs.contains(where: { !$0.ports.isEmpty }) {
            a.append(
                Action(title: "Show Ports") { [weak self] in
                    self?.enter(.ports, query: g.title)
                    return .stay
                }
            )
        }
        if let m = g.main { a.append(sampleAction(m, name: g.title)) }
        a.append(
            Action(title: "Copy PIDs") { [weak self] in
                Pasteboard.copy(g.pids.map(String.init).joined(separator: " "))
                self?.toast("\(g.pids.count) PIDs copied")
                return .stay
            }
        )
        a.append(activityMonitorAction)
        return a
    }

    private func processActions(_ p: ProcInfo) -> [Action] {
        var a = [
            Action(title: "Quit") { [weak self] in
                self?.quit([p], app: nil, name: p.name, force: false)
                return .stay
            },
            Action(title: "Force Quit") { [weak self] in
                self?.quit([p], app: nil, name: p.name, force: true)
                return .stay
            },
        ]
        if let port = p.ports.first {
            a.append(
                Action(title: "Open localhost:\(port)") {
                    openURL("http://localhost:\(port)")
                    return .close
                }
            )
        }
        if let cwd = p.cwd, cwd != "/" {
            a.append(
                Action(title: "Open Folder") {
                    Effects.open(URL(fileURLWithPath: cwd))
                    return .close
                }
            )
        }
        a.append(sampleAction(p, name: p.name))
        a.append(
            Action(title: "Copy Command Line") { [weak self] in
                Pasteboard.copy(p.args.isEmpty ? p.path : p.args.joined(separator: " "))
                self?.toast("Command line copied")
                return .stay
            }
        )
        a.append(
            Action(title: "Copy PID") { [weak self] in
                Pasteboard.copy(String(p.pid))
                self?.toast("PID \(p.pid) copied")
                return .stay
            }
        )
        return a
    }

    private var activityMonitorAction: Action {
        Action(title: "Open Activity Monitor") {
            Effects.openApplication(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            return .close
        }
    }

    /// `sample <pid> 3` into a text file, opened when done.
    private func sampleAction(_ p: ProcInfo, name: String) -> Action {
        Action(title: "Sample for 3 Seconds") { [weak self] in
            guard !Paths.isTestRunner else { return .stay }
            self?.toast("Sampling \(name) for 3 seconds…")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(p.pid)-sample.txt")
            Task { [weak self] in
                do {
                    _ = try await Shell.run("/usr/bin/sample", [String(p.pid), "3", "-file", file.path], timeout: 30)
                    Effects.open(file)
                } catch {
                    self?.toast("Could not sample \(name): \(error.localizedDescription)")
                }
            }
            return .stay
        }
    }

    /// Quits processes: apps through AppKit (so they can ask to save), others with SIGTERM, or SIGKILL
    /// when forced. Processes of another user are quit with an administrator prompt.
    func quit(_ procs: [ProcInfo], app: String?, name: String, force: Bool) {
        if let e = procs.first(where: { essential.contains($0.name) || $0.pid <= 1 }) {
            toast("\(e.name) is part of macOS and can't be quit")
            return
        }
        let targets = procs.filter { $0.pid != getpid() }
        guard !targets.isEmpty, !Paths.isTestRunner else { return }
        if let app {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app }
            if !running.isEmpty {
                for r in running { _ = force ? r.forceTerminate() : r.terminate() }
                toast(force ? "Force quit \(name)" : "Quitting \(name)")
                resampleSoon()
                return
            }
        }
        var denied: [pid_t] = []
        for p in targets where kill(p.pid, force ? SIGKILL : SIGTERM) != 0 && errno == EPERM { denied.append(p.pid) }
        if !denied.isEmpty {
            let pids = denied.map(String.init).joined(separator: " ")
            let script = "do shell script \"kill -\(force ? 9 : 15) \(pids)\" with administrator privileges"
            Task {
                _ = try? await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
                resampleSoon()
            }
        }
        let n = targets.count
        toast(
            (force ? "Force quit " : "Quit ") + (n == 1 ? name : "\(n) \(name) processes")
                + (denied.isEmpty ? "" : " (asking for your password)")
        )
        resampleSoon()
    }

    /// The list shows the change quickly instead of after the next 2-second tick.
    private func resampleSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            let snap = await SystemSampler.shared.sample(network: self.procSort == .network)
            self.snapshot = snap
            if self.mode.samplesProcesses || self.mode == .root {
                self.setItems(self.computeItems(), keepSelection: true)
            }
        }
    }

    // MARK: Leftovers

    var leftoverSummary: (count: Int, memory: UInt64) {
        guard let s = snapshot else { return (0, 0) }
        let idle = ProcModel.leftovers(s).idle.joined()
        return (idle.count, idle.reduce(0) { $0 + $1.memory })
    }

    func leftoverItems() -> [Item] {
        guard let s = snapshot else { return [] }
        let (idle, serving) = ProcModel.leftovers(s)
        let all = Array(idle.joined())
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []
        for (label, trees) in ProcModel.leftoverGroups(idle) {
            let procs = Array(trees.joined())
            let ages = trees.map { s.date.timeIntervalSince($0[0].started) }
            let age =
                ages.count > 1 && Fmt.age(ages.min()!) != Fmt.age(ages.max()!)
                ? "\(Fmt.age(ages.min()!))–\(Fmt.age(ages.max()!))" : Fmt.age(ages.max() ?? 0)
            var it = Item(
                id: "leftover:" + label,
                title: label,
                subtitle: trees.count == 1 ? Fmt.home(trees[0][0].cwd ?? "") : "\(trees.count) copies",
                icon: .symbol("terminal"),
                keywords: procs.map(\.name),
                actions: [
                    Action(title: "Quit") { [weak self] in
                        self?.quit(procs, app: nil, name: label, force: false)
                        return .stay
                    },
                    Action(title: "Quit All Leftovers") { [weak self] in
                        self?.quit(all, app: nil, name: "leftover", force: false)
                        return .stay
                    },
                    Action(title: "Force Quit") { [weak self] in
                        self?.quit(procs, app: nil, name: label, force: true)
                        return .stay
                    },
                    Action(title: "Copy Command Line") { [weak self] in
                        Pasteboard.copy(trees[0][0].args.joined(separator: " "))
                        self?.toast("Command line copied")
                        return .stay
                    },
                ],
                section: "Not in use"
            )
            it.system = .leftover(count: procs.count, age: age, memory: procs.reduce(0) { $0 + $1.memory }, ports: [])
            if q.isEmpty || Fuzzy.best(q, it) != nil { out.append(it) }
        }
        for t in serving {
            let root = t[0]
            let ports = t.flatMap(\.ports).sorted()
            var it = Item(
                id: "serving:\(root.pid)",
                title: ProcModel.shortCommand(root),
                subtitle: Fmt.home(root.cwd ?? ""),
                icon: .symbol("network"),
                actions: [
                    Action(title: "Quit") { [weak self] in
                        self?.quit(t, app: nil, name: ProcModel.shortCommand(root), force: false)
                        return .stay
                    },
                    Action(title: "Open localhost:\(ports.first ?? 0)") {
                        openURL("http://localhost:\(ports.first ?? 0)")
                        return .close
                    },
                ],
                section: "Still serving a port"
            )
            it.system = .leftover(
                count: t.count,
                age: Fmt.age(s.date.timeIntervalSince(root.started)),
                memory: t.reduce(0) { $0 + $1.memory },
                ports: ports
            )
            if q.isEmpty || Fuzzy.best(q, it) != nil { out.append(it) }
        }
        return out
    }

    // MARK: Ports

    func portItems() -> [Item] {
        guard let s = snapshot else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        let order: [ProcModel.PortKind] = [.server, .service, .system]
        var rows: [(ProcModel.PortKind, Int, Item)] = []
        for p in s.procs where !p.ports.isEmpty {
            let kind = ProcModel.portKind(p, launchd: s.launchdJobs)
            // Apps' ephemeral ports (49152+) are their own business.
            let ports = kind == .server ? p.ports : p.ports.filter { $0 < 49152 }
            guard let first = ports.first else { continue }
            let title: String
            let folder: String?
            switch kind {
            case .server:
                title = ProcModel.launcherCommand(p, in: s)
                folder = p.cwd.map(Fmt.home)
            case .service:
                title =
                    p.appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? p.name
                folder = p.appPath == nil ? p.cwd.flatMap { $0 == "/" ? nil : Fmt.home($0) } : nil
            case .system:
                title = ProcModel.systemNames[p.name] ?? p.name
                folder = nil
            }
            let icon: ItemIcon =
                p.appPath.map { .file($0) }
                ?? .symbol(kind == .server ? "terminal" : (kind == .system ? "apple.logo" : "gearshape"))
            var it = Item(
                id: "port:\(p.pid)",
                title: title,
                subtitle: kind == .system && title != p.name ? p.name : "",
                icon: icon,
                keywords: ports.map(String.init) + [p.name] + (folder.map { [$0] } ?? []),
                actions: portActions(p, port: first, name: title, system: kind == .system),
                section: kind.rawValue
            )
            it.system = .port(ports: ports, folder: folder, age: Fmt.age(s.date.timeIntervalSince(p.started)))
            if q.isEmpty
                || ports.contains(where: {
                    String($0).hasPrefix(q.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
                })
                || Fuzzy.best(q, it) != nil
            {
                rows.append((kind, first, it))
            }
        }
        // One row per app or service: Herd's nginx and php processes share one.
        var merged: [(ProcModel.PortKind, Int, Item)] = []
        for r in rows {
            if r.0 != .server, let i = merged.firstIndex(where: { $0.0 == r.0 && $0.2.title == r.2.title }),
                case .port(let a, let folder, let age) = merged[i].2.system!, case .port(let b, _, _) = r.2.system!
            {
                merged[i].2.system = .port(ports: Array(Set(a + b)).sorted(), folder: folder, age: age)
                merged[i].1 = min(merged[i].1, r.1)
            } else {
                merged.append(r)
            }
        }
        return merged.sorted { a, b in
            a.0 != b.0 ? order.firstIndex(of: a.0)! < order.firstIndex(of: b.0)! : a.1 < b.1
        }.map(\.2)
    }

    private func portActions(_ p: ProcInfo, port: Int, name: String, system: Bool) -> [Action] {
        var a = [
            Action(title: "Open in Browser") {
                openURL("http://localhost:\(port)")
                return .close
            }
        ]
        if !system {
            a.append(
                Action(title: "Stop") { [weak self] in
                    self?.quit([p], app: nil, name: name, force: false)
                    return .stay
                }
            )
        }
        a.append(
            Action(title: "Copy URL") { [weak self] in
                Pasteboard.copy("http://localhost:\(port)")
                self?.toast("http://localhost:\(port) copied")
                return .stay
            }
        )
        if let cwd = p.cwd, cwd != "/" {
            a.append(
                Action(title: "Open Folder") {
                    Effects.open(URL(fileURLWithPath: cwd))
                    return .close
                }
            )
        }
        a.append(
            Action(title: "Show Process") { [weak self] in
                guard let self else { return .stay }
                self.enter(.processes)
                self.expandedGroup = ProcModel.groupKey(p).key
                self.refresh()
                return .stay
            }
        )
        return a
    }

    // MARK: Main search

    /// The answer to "5173", ":5173", "port 5173" or "localhost:5173".
    func portAnswer(_ q: String) -> Item? {
        guard let (port, explicit) = ProcModel.portQuery(q), let s = snapshot else { return nil }
        guard let p = s.procs.first(where: { $0.ports.contains(port) }) else {
            guard explicit else { return nil }
            var it = Item(id: "portanswer:\(port)", title: "Nothing is listening on :\(port)")
            it.system = .portAnswer(port: port, facts: nil, folder: nil)
            return it
        }
        let kind = ProcModel.portKind(p, launchd: s.launchdJobs)
        let title =
            kind == .server
            ? ProcModel.launcherCommand(p, in: s)
            : (p.appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? ProcModel.systemNames[p.name] ?? p.name)
        var it = Item(
            id: "portanswer:\(port)",
            title: title,
            actions: portActions(p, port: port, name: title, system: kind == .system)
        )
        let facts = [
            p.name, "pid \(p.pid)", "up \(Fmt.age(s.date.timeIntervalSince(p.started)))", Fmt.memory(p.memory),
        ]
        it.system = .portAnswer(
            port: port,
            facts: facts.joined(separator: " · "),
            folder: p.cwd.flatMap { $0 == "/" ? nil : Fmt.home($0) }
        )
        return it
    }

    /// Running apps among the results get their CPU and memory, Quit actions, and a "Quit <app>" row
    /// under the first one; leftovers matching the query get a row.
    func addRunningInfo(_ items: [Item], query q: String) -> [Item] {
        let running = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { r in r.bundleURL.map { ($0.path, r) } },
            uniquingKeysWith: { a, _ in a }
        )
        let groups = snapshot.map { ProcModel.groups($0.procs, sort: .cpu) } ?? []
        var out: [Item] = []
        var addedQuit = false
        for var it in items {
            guard it.id.hasPrefix("app:") else {
                out.append(it)
                continue
            }
            let path = String(it.id.dropFirst(4))
            guard running[path] != nil else {
                out.append(it)
                continue
            }
            let name = it.title
            if let g = groups.first(where: { $0.appPath == path }) {
                it.subtitle = "Running · \(Fmt.percent(g.cpu)) CPU · \(Fmt.memory(g.memory))"
                it.actions += groupActions(g).prefix(2)
            } else {
                it.subtitle = "Running"
            }
            out.append(it)
            if !addedQuit {
                addedQuit = true
                let procs = groups.first(where: { $0.appPath == path })?.procs ?? []
                let count = procs.count
                out.append(
                    Item(
                        id: "quit:" + path,
                        title: "Quit \(name)",
                        subtitle: count > 1
                            ? "\(count) processes · \(Fmt.memory(procs.reduce(0) { $0 + $1.memory }))" : "",
                        icon: .symbol("power"),
                        accessory: "Command",
                        actions: [
                            Action(title: "Quit") { [weak self] in
                                self?.quitApp(path, name: name, force: false)
                                return .stay
                            },
                            Action(title: "Force Quit") { [weak self] in
                                self?.quitApp(path, name: name, force: true)
                                return .stay
                            },
                        ]
                    )
                )
            }
        }
        if let s = snapshot, !q.isEmpty {
            for (label, trees) in ProcModel.leftoverGroups(ProcModel.leftovers(s).idle) {
                guard Fuzzy.score(q, label) != nil else { continue }
                let procs = Array(trees.joined())
                out.append(
                    Item(
                        id: "leftoverrow:" + label,
                        title: label,
                        subtitle:
                            "\(procs.count) leftover \(procs.count == 1 ? "process" : "processes") · \(Fmt.memory(procs.reduce(0) { $0 + $1.memory }))",
                        icon: .symbol("exclamationmark.triangle"),
                        accessory: "Quit All",
                        actions: [
                            Action(title: "Quit All") { [weak self] in
                                self?.quit(procs, app: nil, name: label, force: false)
                                return .stay
                            }
                        ]
                    )
                )
            }
        }
        return out
    }

    private func quitApp(_ path: String, name: String, force: Bool) {
        guard !Paths.isTestRunner else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
        for a in apps { _ = force ? a.forceTerminate() : a.terminate() }
        toast(force ? "Force quit \(name)" : "Quitting \(name)")
        resampleSoon()
    }

    // MARK: Storage

    func storageItems() -> [Item] {
        let scanner = StorageScanner.shared
        let spots = scanner.spots
        let top = Double(spots.compactMap { scanner.sizes[$0.id]?.bytes }.max() ?? 1)
        let q = query.trimmingCharacters(in: .whitespaces)
        return spots.compactMap { spot in
            let bytes = scanner.sizes[spot.id]?.bytes
            var actions = [
                Action(title: "Show in Finder") {
                    Effects.reveal(spot.url)
                    return .close
                }
            ]
            if spot.clear != nil {
                actions.append(
                    Action(title: "Clear…") { [weak self] in
                        self?.confirmClear(spot, bytes: bytes)
                        return .stay
                    }
                )
            }
            actions.append(
                Action(title: "Measure Again") { [weak self] in
                    StorageScanner.shared.measure(spot)
                    self?.refresh()
                    return .stay
                }
            )
            var it = Item(
                id: "storage:" + spot.id,
                title: spot.title,
                icon: .symbol(spot.clear == nil ? "folder" : "archivebox"),
                keywords: [spot.path],
                actions: actions
            )
            it.system = .storage(
                path: spot.path,
                bytes: scanner.measuring.contains(spot.id) && bytes == nil ? nil : bytes,
                share: bytes.map { Double($0) / max(top, 1) } ?? 0,
                tag: spot.tag
            )
            return q.isEmpty || Fuzzy.best(q, it) != nil ? it : nil
        }
    }

    /// ⌘↵ once explains, ⌘↵ again within 4 seconds clears.
    private func confirmClear(_ spot: StorageSpot, bytes: Int64?) {
        let id = "clear:" + spot.id
        if let p = pendingConfirm, p.id == id, Date().timeIntervalSince(p.at) < 4 {
            pendingConfirm = nil
            toast("Clearing \(spot.title)…")
            StorageScanner.shared.clear(spot) { [weak self] message in self?.toast(message) }
            return
        }
        pendingConfirm = (id, Date())
        let size = bytes.map { " (\(Fmt.bytes($0)))" } ?? ""
        let what: String
        switch spot.clear {
        case .command(let c): what = "run `\(c)`"
        default: what = "delete everything in \(spot.path)\(size)"
        }
        toast("Press ⌘↵ again to \(what)")
    }
}
