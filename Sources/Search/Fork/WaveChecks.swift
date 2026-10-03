import AppKit

/// Small, isolated regressions for the bench; never run against a user's session.
@MainActor
enum WaveChecks {
    static func run() -> [String] {
        guard Store.testing else { return ["only in a probe world"] }
        var failures: [String] = []
        let before = Agent.Item(kind: .tool, text: "before")
        let driver = Agent.Item(kind: .drive, text: "outside")
        let after = Agent.Item(kind: .tool, text: "after")
        let blocks = AgentPane.blocks([before, driver, after], busy: false)
        if blocks.count != 3 { failures.append("a later tool folded above an outside driver") }
        var pending = before
        pending.running = true
        let interleaved = AgentPane.blocks([pending, driver], busy: true)
        if let first = interleaved.first, case .activity(let group) = first, group.running {} else {
            failures.append("an outside card made an in-flight local tool look finished")
        }

        let drive = Drive.shared
        let agent = Agent.shared
        agent.clear()
        let tab = Tab(bench: true)
        drive.begin(driver: .jev, goal: "regression", tab: tab)
        let jevID = drive.run?.id
        if let ticket = drive.began(call: "browser_get_text", args: [:], by: .agent("Probe peer"), tab: tab) {
            drive.ended(ticket, error: nil, summary: "Read alongside Jev", tab: tab)
            if agent.run(ticket.run)?.cycles.first?.outcome?.result != "Read alongside Jev" {
                failures.append("concurrent call result lost")
            }
        } else { failures.append("concurrent call missing from transcript") }
        if let ticket = drive.began(call: "browser_get_text", args: [:], by: .agent("Stopped peer"), tab: tab) {
            drive.stop(ticket.who)
            drive.ended(ticket, error: nil, summary: "Late after Stop", tab: tab)
            if agent.run(ticket.run)?.status != .stopped { failures.append("late completion erased Stop") }
        }
        drive.resume()
        if drive.run?.id != jevID { failures.append("concurrent caller replaced Jev") }
        drive.finish(.done, note: "regression")
        if let ticket = drive.began(call: "browser_get_text", args: [:], by: .agent("First"), tab: tab) {
            drive.begin(driver: .agent("Second"), tab: tab)
            drive.ended(ticket, error: nil, summary: "Late result", tab: tab)
            if agent.run(ticket.run)?.cycles.first?.outcome?.result != "Late result" {
                failures.append("archived caller lost its completion")
            }
        }
        drive.finish(.done, note: "regression")
        drive.dismiss()
        agent.clear()
        agent.open = false
        tab.close()

        let sleeping = Tab(bench: true)
        sleeping.restore(url: URL(string: "https://example.com/restore-regression")!, title: "Restore")
        sleeping.wake()
        sleeping.rest()
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        if sleeping.built != nil || !sleeping.asleep { failures.append("a delayed wake resurrected a discarded view") }
        sleeping.close()
        return failures
    }
}
