import Darwin
import Foundation
import IOKit.ps

// MARK: - Model

/// One process as sampled. Processes of other users (root daemons, WindowServer) can't be read in
/// detail without privileges: their CPU and memory come from `ps`, and `readable` is false.
struct ProcInfo: Sendable, Equatable {
    var pid: pid_t
    var ppid: pid_t
    var uid: uid_t
    /// Executable name (from the path when readable, else the kernel's 16-character name).
    var name: String
    /// Executable path; empty when unreadable.
    var path = ""
    /// Command line; empty for other users' processes.
    var args: [String] = []
    var started = Date.distantPast
    /// Working folder; nil for other users' processes.
    var cwd: String?
    /// Percent of one core (100 = one core busy), like Activity Monitor.
    var cpu = 0.0
    /// Bytes: the memory footprint, or the resident size when unreadable.
    var memory: UInt64 = 0
    /// Bytes per second read and written.
    var disk = 0.0
    /// Bytes per second in and out; 0 unless network sampling is on.
    var network = 0.0
    /// TCP ports it listens on.
    var ports: [Int] = []
    var readable = false

    /// Folder of the outermost `.app` bundle the executable lives in.
    var appPath: String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// The command line for people: the executable's name, then its arguments, home as `~`.
    var commandLine: String {
        guard let first = args.first else { return name }
        let rest = args.dropFirst().map(Fmt.home)
        return ([(first as NSString).lastPathComponent] + rest).joined(separator: " ")
    }
}

/// The whole machine.
struct SystemStats: Sendable, Equatable {
    /// Busy share of all cores, 0…100.
    var cpu = 0.0
    /// Busy share per core, 0…100.
    var cores: [Double] = []
    var load = 0.0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    var pressure = 1
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// Space for new files, counting what macOS can purge (the figure Finder shows).
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    /// nil without a battery.
    var battery: Int?
    var onPower = true
    var uptime: TimeInterval = 0
}

struct SystemSnapshot: Sendable {
    var date: Date
    var procs: [ProcInfo]
    var stats: SystemStats
    /// Pids launchd runs as jobs (brew services, app agents): never leftovers.
    var launchdJobs: Set<pid_t>
    var ownUID: uid_t
    /// Whether `network` was sampled.
    var hasNetwork: Bool

    func proc(_ pid: pid_t) -> ProcInfo? { procs.first { $0.pid == pid } }
}

// MARK: - Sampler

/// Reads processes and machine stats. Rates (CPU, disk, network) are differences against the previous
/// sample; the first sample takes CPU from `ps`.
actor SystemSampler {
    static let shared = SystemSampler()

    private var lastCPU: [pid_t: (time: UInt64, disk: UInt64, at: UInt64)] = [:]
    private var lastNet: [pid_t: (bytes: UInt64, at: Date)] = [:]
    private var lastTicks: [[UInt32]] = []
    private var launchd: (pids: Set<pid_t>, at: Date) = ([], .distantPast)
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(t.denom))
    }()

    func sample(network: Bool = false) -> SystemSnapshot {
        let now = mach_absolute_time()
        let me = getuid()
        let ps = SystemSampler.psTable()
        var procs: [ProcInfo] = []
        var seen: [pid_t: (UInt64, UInt64, UInt64)] = [:]
        for k in SystemSampler.kinfoAll() {
            let pid = k.kp_proc.p_pid
            guard pid > 0 else { continue }
            var p = ProcInfo(
                pid: pid,
                ppid: k.kp_eproc.e_ppid,
                uid: k.kp_eproc.e_ucred.cr_uid,
                name: SystemSampler.comm(k)
            )
            let st = k.kp_proc.p_starttime
            p.started = Date(timeIntervalSince1970: Double(st.tv_sec) + Double(st.tv_usec) / 1e6)
            if let path = SystemSampler.path(pid) {
                p.path = path
                p.name = (path as NSString).lastPathComponent
            }
            if let ri = SystemSampler.rusage(pid) {
                p.readable = true
                p.memory = ri.ri_phys_footprint
                let cpuTime = (ri.ri_user_time + ri.ri_system_time) * timebase.numer / timebase.denom
                let io = ri.ri_diskio_bytesread + ri.ri_diskio_byteswritten
                seen[pid] = (cpuTime, io, now)
                if let prev = lastCPU[pid], now > prev.at {
                    let wall = Double((now - prev.at) * timebase.numer / timebase.denom)
                    p.cpu = Double(cpuTime &- prev.time) / wall * 100
                    p.disk = Double(io &- prev.disk) / (wall / 1e9)
                } else {
                    p.cpu = ps[pid]?.cpu ?? 0
                }
                if p.uid == me {
                    p.args = SystemSampler.args(pid)
                    // Versioned installs (~/.local/share/claude/versions/2.1.330): the name it was started as.
                    if p.name.first?.isNumber == true, let a0 = p.args.first {
                        p.name = (a0 as NSString).lastPathComponent
                    }
                    p.cwd = SystemSampler.cwd(pid)
                    p.ports = SystemSampler.listeningPorts(pid)
                }
            } else if let row = ps[pid] {
                p.cpu = row.cpu
                p.memory = row.rss
            }
            if p.cpu.isNaN || p.cpu < 0 { p.cpu = 0 }
            procs.append(p)
        }
        lastCPU = seen.mapValues { (time: $0.0, disk: $0.1, at: $0.2) }

        var hasNetwork = false
        if network, let bytes = SystemSampler.nettop() {
            hasNetwork = true
            let at = Date()
            var next: [pid_t: (UInt64, Date)] = [:]
            for i in procs.indices {
                guard let b = bytes[procs[i].pid] else { continue }
                if let prev = lastNet[procs[i].pid] {
                    procs[i].network = Double(b &- prev.bytes) / max(0.5, at.timeIntervalSince(prev.at))
                }
                next[procs[i].pid] = (b, at)
            }
            lastNet = next.mapValues { (bytes: $0.0, at: $0.1) }
        }

        if Date().timeIntervalSince(launchd.at) > 30 { launchd = (SystemSampler.launchdJobs(), Date()) }
        return SystemSnapshot(
            date: Date(),
            procs: procs,
            stats: stats(),
            launchdJobs: launchd.pids,
            ownUID: me,
            hasNetwork: hasNetwork
        )
    }

    // MARK: Machine

    private func stats() -> SystemStats {
        var s = SystemStats()
        // CPU per core: ticks since the previous sample.
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
            let info
        {
            var ticks: [[UInt32]] = []
            for c in 0..<Int(count) {
                let base = c * Int(CPU_STATE_MAX)
                ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
            let prev = lastTicks.count == ticks.count ? lastTicks : ticks.map { _ in [UInt32](repeating: 0, count: 4) }
            s.cores = zip(ticks, prev).map { now, before in
                let d = (0..<4).map { Double(now[$0] &- before[$0]) }
                let total = d.reduce(0, +)
                return total > 0 ? (total - d[Int(CPU_STATE_IDLE)]) / total * 100 : 0
            }
            s.cpu = s.cores.isEmpty ? 0 : s.cores.reduce(0, +) / Double(s.cores.count)
            lastTicks = ticks
        }
        var load = [0.0, 0, 0]
        if getloadavg(&load, 3) > 0 { s.load = load[0] }

        // Memory used as Activity Monitor counts it: app memory + wired + compressed.
        var vm = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        if ok == KERN_SUCCESS {
            let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
            s.memoryUsed = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        s.memoryTotal = ProcessInfo.processInfo.physicalMemory
        s.pressure = SystemSampler.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }
        (s.diskFree, s.diskTotal) = SystemSampler.diskSpace()
        (s.battery, s.onPower) = SystemSampler.battery()
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0 {
            s.uptime = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }
        return s
    }

    /// Free (including what macOS can purge, as Finder counts it) and total bytes of the startup disk.
    static func diskSpace() -> (free: Int64, total: Int64) {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? root.resourceValues(forKeys: keys) else { return (0, 0) }
        return (v.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v.volumeTotalCapacity ?? 0))
    }

    private static func battery() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, true) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (cur * 100 / max, d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return (nil, true)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    // MARK: Processes

    static func kinfoAll() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func comm(_ k: kinfo_proc) -> String {
        var c = k.kp_proc.p_comm
        return withUnsafePointer(to: &c) { $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) } }
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var ri = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? ri : nil
    }

    /// argv from `KERN_PROCARGS2`: argc, the exec path, padding, then the arguments.
    static func args(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }  // exec path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard n > 0 else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func listeningPorts(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            guard
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                si.psi.soi_kind == SOCKINFO_TCP, si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            ports.insert(
                Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            )
        }
        return ports.sorted()
    }

    /// `/bin/ps` runs as root, so it sees CPU and resident memory of every process.
    static func psTable() -> [pid_t: (cpu: Double, rss: UInt64)] {
        guard let out = runTool("/bin/ps", ["-Ao", "pid=,pcpu=,rss="]) else { return [:] }
        var t: [pid_t: (Double, UInt64)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let cpu = Double(f[1]), let rss = UInt64(f[2]) else { continue }
            t[pid] = (cpu, rss * 1024)
        }
        return t.mapValues { (cpu: $0.0, rss: $0.1) }
    }

    /// Total bytes in + out per pid since each process started (`nettop` lines are `name.pid,in,out,`).
    static func nettop() -> [pid_t: UInt64]? {
        guard let out = runTool("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"], timeout: 5)
        else { return nil }
        var t: [pid_t: UInt64] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."), let pid = pid_t(f[0][f[0].index(after: dot)...])
            else {
                continue
            }
            t[pid] = (UInt64(f[1]) ?? 0) + (UInt64(f[2]) ?? 0)
        }
        return t
    }

    /// Pids of running launchd jobs in this user's domain.
    static func launchdJobs() -> Set<pid_t> {
        guard let out = runTool("/bin/launchctl", ["list"]) else { return [] }
        return Set(out.split(separator: "\n").dropFirst().compactMap { pid_t($0.split(separator: "\t").first ?? "") })
    }

    static func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

// MARK: - Grouping

/// What the processes list sorts by.
enum ProcSort: String, CaseIterable, Sendable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"

    func value(_ p: ProcInfo) -> Double {
        switch self {
        case .cpu: return p.cpu
        case .memory: return Double(p.memory)
        case .disk: return p.disk
        case .network: return p.network
        }
    }

    var next: ProcSort {
        let all = ProcSort.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Processes of one app (its helpers too) or of one executable name.
struct ProcGroup: Sendable {
    var key: String
    var title: String
    var appPath: String?
    var procs: [ProcInfo]

    var cpu: Double { procs.reduce(0) { $0 + $1.cpu } }
    var memory: UInt64 { procs.reduce(0) { $0 + $1.memory } }
    var disk: Double { procs.reduce(0) { $0 + $1.disk } }
    var network: Double { procs.reduce(0) { $0 + $1.network } }
    var pids: [pid_t] { procs.map(\.pid) }

    func value(_ s: ProcSort) -> Double {
        switch s {
        case .cpu: return cpu
        case .memory: return Double(memory)
        case .disk: return disk
        case .network: return network
        }
    }

    /// Part of macOS: every process lives under /System, /usr or /sbin.
    var isSystem: Bool {
        if let app = appPath, app.hasPrefix("/System/Applications") || app.hasPrefix("/Applications") { return false }
        return procs.allSatisfy { p in
            let path = p.path.isEmpty ? "/usr/" : p.path
            return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
        }
    }

    /// Main process first: the app's own executable, else the oldest.
    var main: ProcInfo? {
        if let app = appPath {
            let exe = app + "/Contents/MacOS/"
            if let m = procs.first(where: { $0.path.hasPrefix(exe) }) { return m }
        }
        return procs.min { $0.started < $1.started }
    }
}

enum ProcModel {
    static func groupKey(_ p: ProcInfo) -> (key: String, title: String, app: String?) {
        if let app = p.appPath {
            return ("app:" + app, ((app as NSString).lastPathComponent as NSString).deletingPathExtension, app)
        }
        return ("cmd:" + p.name, p.name, nil)
    }

    /// Groups sorted by `sort`, largest first.
    static func groups(_ procs: [ProcInfo], sort: ProcSort) -> [ProcGroup] {
        var byKey: [String: ProcGroup] = [:]
        var order: [String] = []
        for p in procs {
            let g = groupKey(p)
            if byKey[g.key] == nil {
                byKey[g.key] = ProcGroup(key: g.key, title: g.title, appPath: g.app, procs: [])
                order.append(g.key)
            }
            byKey[g.key]!.procs.append(p)
        }
        return order.compactMap { byKey[$0] }.sorted {
            let a = $0.value(sort)
            let b = $1.value(sort)
            return a != b ? a > b : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: Leftovers

    static let runtimes: Set<String> = [
        "node", "npm", "npx", "bun", "bunx", "deno", "python", "python3", "uv", "uvx", "ruby", "tsx", "ts-node",
        "esbuild", "vite", "next-server", "pnpm", "yarn", "java", "go", "cargo",
    ]

    /// A dev tool: a JavaScript, Python or similar runtime, or anything that calls itself an MCP server.
    static func isDevTool(_ p: ProcInfo) -> Bool {
        let n = p.name.lowercased()
        if runtimes.contains(n) || n.hasPrefix("python3") || n.contains("mcp") { return true }
        return p.args.prefix(3).contains { ($0 as NSString).lastPathComponent.lowercased().contains("mcp") }
    }

    /// Dev tools nothing is using any more: orphaned (parent is launchd), not a launchd job, outside app
    /// bundles, with every process they started. Those still listening on a port are `serving`.
    /// Each leftover is a tree: the orphaned process first, then everything it started.
    static func leftovers(_ s: SystemSnapshot) -> (idle: [[ProcInfo]], serving: [[ProcInfo]]) {
        var children: [pid_t: [ProcInfo]] = [:]
        for p in s.procs { children[p.ppid, default: []].append(p) }
        func tree(_ p: ProcInfo) -> [ProcInfo] { [p] + (children[p.pid] ?? []).flatMap(tree) }
        var idle: [[ProcInfo]] = []
        var serving: [[ProcInfo]] = []
        for root in s.procs
        where root.uid == s.ownUID && root.ppid == 1 && !s.launchdJobs.contains(root.pid) && root.appPath == nil
            && isDevTool(root)
        {
            let t = tree(root)
            if t.contains(where: { !$0.ports.isEmpty }) { serving.append(t) } else { idle.append(t) }
        }
        return (idle, serving)
    }

    /// Leftover trees grouped by label, most memory first.
    static func leftoverGroups(_ trees: [[ProcInfo]]) -> [(label: String, trees: [[ProcInfo]])] {
        var byLabel: [String: [[ProcInfo]]] = [:]
        for t in trees { byLabel[label(t[0]), default: []].append(t) }
        func mem(_ ts: [[ProcInfo]]) -> UInt64 { ts.joined().reduce(0) { $0 + $1.memory } }
        return byLabel.map { ($0.key, $0.value) }.sorted {
            mem($0.1) != mem($1.1) ? mem($0.1) > mem($1.1) : $0.0 < $1.0
        }
    }

    /// A short command for a list: the program and its first words, paths reduced to file names.
    static func shortCommand(_ p: ProcInfo, words: Int = 4) -> String {
        let args = p.args.filter { !$0.isEmpty }
        guard let first = args.first else { return p.name }
        let rest = args.dropFirst().prefix(words - 1).map { $0.contains("/") ? ($0 as NSString).lastPathComponent : $0 }
        return ([(first as NSString).lastPathComponent] + rest).joined(separator: " ")
    }

    /// What started a server, for people: `bun run dev` rather than the node process it spawned.
    static func launcherCommand(_ p: ProcInfo, in s: SystemSnapshot) -> String {
        // npm rewrites its argv to "npm run dev", so look at the command, not the executable (node).
        if let parent = s.proc(p.ppid), parent.uid == p.uid,
            let tool = shortCommand(parent).split(separator: " ").first,
            ["npm", "bun", "pnpm", "yarn", "npx", "bunx", "deno"].contains(String(tool))
        {
            return shortCommand(parent)
        }
        return shortCommand(p)
    }

    /// What a leftover is, from its command line: an MCP server's name, a script's name, else the tool.
    static func label(_ p: ProcInfo) -> String {
        let words = p.args.dropFirst().filter { !$0.hasPrefix("-") }
        func base(_ s: String) -> String {
            let b = (s as NSString).lastPathComponent
            for ext in [".js", ".cjs", ".mjs", ".ts", ".py"] where b.hasSuffix(ext) {
                return String(b.dropLast(ext.count))
            }
            return b
        }
        let first = p.args.first.map(base) ?? p.name
        if first.lowercased().contains("mcp") { return first }
        if let m = words.first(where: { base($0).lowercased().contains("mcp") }) {
            let b = base(m)
            // `node …/qmd.js mcp`: the word before `mcp` names it.
            if b == "mcp", let i = words.firstIndex(of: m), i > words.startIndex {
                return base(words[words.index(before: i)]) + " mcp"
            }
            return b
        }
        if ["npm", "npx", "bun", "bunx", "uv", "uvx", "pnpm", "yarn"].contains(first) {
            return ([first] + words.prefix(2).map(base)).joined(separator: " ")
        }
        if let script = words.first(where: { w in [".js", ".cjs", ".mjs", ".ts", ".py"].contains { w.hasSuffix($0) } })
        {
            return base(script)
        }
        return first
    }

    // MARK: Ports

    enum PortKind: String, Sendable {
        case server = "Your servers"
        case service = "Services"
        case system = "macOS"
    }

    static let systemNames: [String: String] = [
        "ControlCenter": "AirPlay Receiver",
        "rapportd": "Handoff",
        "sharingd": "Sharing",
        "remoted": "Remote Management",
    ]

    static func portKind(_ p: ProcInfo, launchd: Set<pid_t>) -> PortKind {
        if systemNames[p.name] != nil || p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/") { return .system }
        let home = NSHomeDirectory()
        if let cwd = p.cwd, cwd.hasPrefix(home + "/"), !cwd.hasPrefix(home + "/Library"), !launchd.contains(p.pid),
            p.appPath == nil
        {
            return .server
        }
        return .service
    }

    /// `5173`, `:5173`, `port 5173`, `localhost:5173`, `127.0.0.1:5173`. `explicit` when the query says
    /// it is a port (anything but a bare number).
    static func portQuery(_ q: String) -> (port: Int, explicit: Bool)? {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixes = ["http://localhost:", "localhost:", "127.0.0.1:", "port ", ":"]
        var explicit = false
        var rest = Substring(t)
        for pre in prefixes where rest.hasPrefix(pre) {
            rest = rest.dropFirst(pre.count)
            explicit = true
            break
        }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        guard (2...5).contains(rest.count), rest.allSatisfy(\.isASCII), let n = Int(rest), (1...65535).contains(n)
        else { return nil }
        return (n, explicit)
    }
}

// MARK: - Formatting

enum Fmt {
    static func home(_ s: String) -> String {
        let h = NSHomeDirectory()
        return s == h ? "~" : (s.hasPrefix(h + "/") ? "~" + s.dropFirst(h.count) : s)
    }

    /// 3.9 GB, 286 MB, 4 KB (decimal units, like Finder and Activity Monitor).
    static func bytes<T: BinaryInteger>(_ n: T) -> String { bytes(Double(n)) }

    static func bytes(_ d: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = d
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if i == 0 { return "\(Int(v)) B" }
        return (v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))) + " " + units[i]
    }

    /// Memory in binary units, as Activity Monitor shows it: 32 GB of RAM, not 34.
    static func memory<T: BinaryInteger>(_ n: T) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v)) B" }
        return (v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))) + " " + units[i]
    }

    static func rate(_ d: Double) -> String { d < 1 ? "0 B/s" : bytes(d) + "/s" }

    static func percent(_ d: Double) -> String { String(format: d < 10 ? "%.1f%%" : "%.0f%%", d) }

    /// 45s, 12m, 3h 20m, 4d 12h.
    static func age(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
        default: return "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }
}
