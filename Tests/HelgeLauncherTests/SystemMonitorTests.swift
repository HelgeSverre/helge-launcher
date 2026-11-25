import Foundation
import Testing

@testable import HelgeLauncher

@Suite struct SystemMonitorTests {
    let me: uid_t = 501
    let home = NSHomeDirectory()

    func proc(
        _ pid: pid_t,
        _ ppid: pid_t,
        _ name: String,
        path: String = "",
        args: [String] = [],
        cwd: String? = nil,
        cpu: Double = 0,
        memory: UInt64 = 0,
        ports: [Int] = [],
        uid: uid_t = 501
    ) -> ProcInfo {
        var p = ProcInfo(pid: pid, ppid: ppid, uid: uid, name: name)
        p.path = path
        p.args = args
        p.cwd = cwd
        p.cpu = cpu
        p.memory = memory
        p.ports = ports
        p.readable = true
        return p
    }

    func snapshot(_ procs: [ProcInfo], launchd: Set<pid_t> = []) -> SystemSnapshot {
        SystemSnapshot(
            date: Date(),
            procs: procs,
            stats: SystemStats(),
            launchdJobs: launchd,
            ownUID: me,
            hasNetwork: false
        )
    }

    @Test func helpersGroupUnderTheirApp() {
        let chrome = "/Applications/Google Chrome.app"
        let procs = [
            proc(10, 1, "Google Chrome", path: chrome + "/Contents/MacOS/Google Chrome", cpu: 5, memory: 100),
            proc(
                11,
                10,
                "Google Chrome Helper",
                path: chrome
                    + "/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                cpu: 30,
                memory: 300
            ),
            proc(20, 1, "node", path: "/opt/homebrew/bin/node", cpu: 1, memory: 900),
            proc(
                21,
                1,
                "WindowServer",
                path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                cpu: 10,
                uid: 88
            ),
        ]
        let byCPU = ProcModel.groups(procs, sort: .cpu)
        #expect(byCPU.map(\.title) == ["Google Chrome", "WindowServer", "node"])
        #expect(byCPU[0].procs.count == 2 && byCPU[0].cpu == 35 && byCPU[0].main?.pid == 10)
        #expect(byCPU[1].isSystem && !byCPU[0].isSystem)
        #expect(ProcModel.groups(procs, sort: .memory).first?.title == "node")
        #expect(ProcSort.cpu.next == .memory && ProcSort.network.next == .cpu)
    }

    @Test func leftoversAreOrphanedIdleDevToolsOnly() {
        let procs = [
            // Orphaned MCP server and the bun process it started.
            proc(100, 1, "node", args: ["chrome-devtools-mcp"], memory: 145),
            proc(101, 100, "bun", args: ["bun", "x"], memory: 5),
            // Orphaned dev server: still serving.
            proc(200, 1, "node", args: ["npm run dev"], cwd: home + "/code/app", ports: [5199]),
            // brew service (launchd job), app helper, other user, live parent: not leftovers.
            proc(300, 1, "mailpit", path: "/opt/homebrew/opt/mailpit/bin/mailpit", ports: [8025]),
            proc(301, 1, "node", path: "/Applications/ChatGPT.app/Contents/Resources/node"),
            proc(302, 1, "python3", uid: 0),
            proc(303, 999, "node", args: ["node", "server.js"]),
            proc(304, 1, "node", args: ["node", "agent.js"]),
        ]
        let (idle, serving) = ProcModel.leftovers(snapshot(procs, launchd: [304]))
        #expect(idle.map { $0.map(\.pid) } == [[100, 101]])
        #expect(serving.map { $0[0].pid } == [200])
        #expect(ProcModel.leftoverGroups(idle).first?.label == "chrome-devtools-mcp")
    }

    @Test func leftoverLabels() {
        #expect(ProcModel.label(proc(1, 1, "node", args: ["node", "/x/.bun/bin/qmd", "mcp"])) == "qmd mcp")
        #expect(ProcModel.label(proc(1, 1, "node", args: ["npm", "exec", "context7-mcp"])) == "context7-mcp")
        #expect(ProcModel.label(proc(1, 1, "node", args: ["node", "./mcp/server.cjs", "--stdio"])) == "server")
        #expect(ProcModel.label(proc(1, 1, "node", args: ["node", "/a/b/index.js"])) == "index")
        #expect(ProcModel.label(proc(1, 1, "bun", args: ["bun", "run", "dev"])) == "bun run dev")
    }

    @Test func portQueries() {
        #expect(ProcModel.portQuery("5173")! == (5173, false))
        #expect(ProcModel.portQuery(":3000")! == (3000, true))
        #expect(ProcModel.portQuery("port 8080")! == (8080, true))
        #expect(ProcModel.portQuery("localhost:5173/")! == (5173, true))
        #expect(ProcModel.portQuery("http://localhost:4321")! == (4321, true))
        #expect(ProcModel.portQuery("99999") == nil)
        #expect(ProcModel.portQuery("5") == nil)
        #expect(ProcModel.portQuery("12 days") == nil)
    }

    @Test func portKindsAndNames() {
        let server = proc(
            2,
            1,
            "node",
            args: ["node", "/x/node_modules/.bin/vite"],
            cwd: home + "/code/app",
            ports: [5173]
        )
        let npm = proc(1, 1, "node", args: ["npm run dev", "", ""], cwd: home + "/code/app")
        var child = server
        child.ppid = 1
        child.pid = 3
        let s = snapshot([
            npm,
            {
                var c = server
                c.ppid = 1
                return c
            }(),
        ])
        #expect(ProcModel.portKind(server, launchd: []) == .server)
        #expect(ProcModel.portKind(server, launchd: [2]) == .service)
        #expect(
            ProcModel.portKind(
                proc(
                    4,
                    1,
                    "ControlCenter",
                    path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
                ),
                launchd: []
            ) == .system
        )
        var spawned = server
        spawned.ppid = 1
        #expect(ProcModel.launcherCommand(spawned, in: s) == "npm run dev")
        #expect(ProcModel.launcherCommand(child, in: snapshot([child])) == "node vite")
    }

    @Test func formats() {
        #expect(Fmt.bytes(2_652_357_120) == "2.7 GB")
        #expect(Fmt.memory(UInt64(34_359_738_368)) == "32 GB")
        #expect(
            Fmt.age(45) == "45s" && Fmt.age(3 * 3600 + 20 * 60) == "3h 20m"
                && Fmt.age(4 * 86400 + 12 * 3600) == "4d 12h"
        )
        #expect(Fmt.home(home + "/code/x") == "~/code/x")
    }

    @Test func samplerReadsThisProcess() async {
        let s = await SystemSampler.shared.sample()
        let me = s.proc(getpid())
        #expect(me != nil && me!.readable && me!.memory > 0 && !me!.args.isEmpty)
        #expect(s.stats.memoryTotal > 0 && s.stats.diskTotal > 0 && !s.stats.cores.isEmpty)
    }
}
