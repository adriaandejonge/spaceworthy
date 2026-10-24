import Foundation

enum Recommendations {
    static let GB: Int64 = 1_000_000_000
    static let softwareUpdateURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!

    @MainActor
    static func build(_ m: AppModel) -> [Recommendation] {
        var recs: [Recommendation] = []
        var used = Set<String>()
        let freeFraction = m.disk?.freeFraction ?? 1

        func action(for s: LocationState) -> RecommendationAction {
            switch s.location.actionKind {
            case .trash, .emptyTrash: .clean(s.id)
            case .command: s.location.command.map { .copy($0) } ?? .reveal(s.location.url)
            default: .reveal(s.location.url)
            }
        }

        // 1. Pending macOS installer/update.
        let installer = m.states.filter { $0.location.isInstaller || $0.id == "libUpdates" }
        let installerBytes = installer.reduce(0) { $0 + $1.bytes }
        if installerBytes > 500_000_000 {
            recs.append(Recommendation(
                id: "macos-update", title: "Install or remove the downloaded macOS update",
                rationale: "A macOS installer/update is downloaded but not installed (\(Fmt.bytes(installerBytes))). Installing it and restarting frees that space; or delete the Install app if you don't want it.",
                bytes: installerBytes, severity: .high,
                action: .openURL(softwareUpdateURL, label: "Software Update…")))
            installer.forEach { used.insert($0.id) }
        }

        // 1b. Claude Code worktrees and job data.
        let wts = m.worktreeStates
        let wtBytes = wts.reduce(0) { $0 + $1.bytes }
        let jobs = m.state("claudeJobs")
        let jobBytes = jobs?.bytes ?? 0
        if wtBytes > 2 * GB || jobBytes > 1 * GB {
            let all = m.allWorktrees
            let safeWT = all.filter { $0.verdict == .safe }
            let safeBytes = safeWT.reduce(0) { $0 + $1.bytes }
            let old30 = all.filter { $0.ageDays > 30 }.reduce(0) { $0 + $1.bytes }
            let stale = all.filter(\.isStale).count
            let loading = wts.contains { $0.gitLoading }
            var parts: [String] = []
            if !all.isEmpty {
                let repos = wts.sorted { $0.bytes > $1.bytes }.map(\.repoName)
                parts.append("\(all.count) agent worktrees in \(repos.prefix(3).joined(separator: ", ")) (\(Fmt.bytes(wtBytes)))")
            }
            if jobBytes > 0 { parts.append("\(Fmt.bytes(jobBytes)) of job data") }
            var rationale = parts.joined(separator: " and ") + "."
            if loading {
                rationale += " Checking git status of each worktree…"
            } else if !all.isEmpty {
                rationale += " \(safeWT.count) worktree\(safeWT.count == 1 ? " is" : "s are") merged and clean (\(Fmt.bytes(safeBytes)) safe to remove)"
                rationale += stale * 2 > all.count ? "; most are over a week old." : "."
                if old30 > 0 { rationale += " \(Fmt.bytes(old30)) is older than 30 days." }
            }
            let estimate = safeBytes + m.oldJobBytes
            let top = wts.max { $0.bytes < $1.bytes }
            let act: RecommendationAction
            if let top, top.bytes >= jobBytes { act = .show(top.id, label: "Review worktrees") }
            else if let jobs { act = .show(jobs.id, label: "Review jobs") }
            else { act = .none }
            recs.append(Recommendation(
                id: "claude", title: "Claude Code is using \(Fmt.bytes(wtBytes + jobBytes))",
                rationale: rationale, bytes: estimate > 0 ? estimate : nil, severity: .high, action: act))
            wts.forEach { used.insert($0.id) }
            if let jobs { used.insert(jobs.id) }
        }

        // 2. Big safe-to-clean locations, Trash > 1 GB.
        let safe = m.states(in: .safe).filter { !used.contains($0.id) }.sorted { $0.bytes > $1.bytes }
        for s in safe {
            if s.location.actionKind == .emptyTrash {
                guard s.bytes > GB else { continue }
                recs.append(Recommendation(
                    id: s.id, title: "Empty the Trash",
                    rationale: "\(Fmt.bytes(s.bytes)) is sitting in the Trash and still takes up disk space.",
                    bytes: s.bytes, severity: .medium, action: .clean(s.id)))
                used.insert(s.id)
            } else if s.bytes > 2 * GB {
                // Locations nested in a bigger one (e.g. Homebrew inside ~/Library/Caches) are folded into it.
                let p = s.location.url.path
                if safe.contains(where: { $0.id != s.id && $0.bytes > 2 * GB && p.hasPrefix($0.location.url.path + "/") }) {
                    continue
                }
                let nested = safe.filter { $0.id != s.id && $0.bytes > 500_000_000 && $0.location.url.path.hasPrefix(p + "/") }
                var rationale = s.location.cleanHint
                if !nested.isEmpty {
                    rationale += " Includes " + nested.map { "\($0.location.title) (\(Fmt.bytes($0.bytes)))" }
                        .joined(separator: ", ") + "."
                    nested.forEach { used.insert($0.id) }
                }
                let verb = s.location.actionKind == .revealOnly ? "Review" : "Clean"
                recs.append(Recommendation(
                    id: s.id, title: "\(verb) \(s.location.title) (frees ~\(Fmt.bytes(s.bytes)))",
                    rationale: rationale,
                    bytes: s.bytes, severity: s.bytes > 10 * GB ? .high : .medium, action: action(for: s)))
                used.insert(s.id)
            }
        }

        // 3. Docker data > 10 GB.
        if let d = m.state("docker"), d.bytes > 10 * GB, !used.contains(d.id) {
            recs.append(Recommendation(
                id: "docker", title: "Prune Docker (\(Fmt.bytes(d.bytes)))",
                rationale: "Removes stopped containers, unused images and build cache.",
                bytes: d.bytes, severity: .high, action: .copy("docker system prune -a")))
            used.insert(d.id)
        }

        // 4. Xcode DerivedData + simulators > 5 GB.
        let xc = ["derivedData", "simDevices", "simCaches"].compactMap { m.state($0) }.filter { !used.contains($0.id) }
        let xcBytes = xc.reduce(0) { $0 + $1.bytes }
        if xcBytes > 5 * GB {
            recs.append(Recommendation(
                id: "xcode", title: "Trim Xcode build data and simulators (\(Fmt.bytes(xcBytes)))",
                rationale: "DerivedData rebuilds on demand; `xcrun simctl delete unavailable` removes stale simulators.",
                bytes: xcBytes, severity: .medium, action: .copy("xcrun simctl delete unavailable")))
            xc.forEach { used.insert($0.id) }
        }

        // 5. Old downloads.
        if let dl = m.state("downloads"), dl.oldBytes > 2 * GB {
            recs.append(Recommendation(
                id: "downloads", title: "Review old downloads (\(Fmt.bytes(dl.oldBytes)))",
                rationale: "Files in Downloads not modified for over 30 days are usually installers and one-off files.",
                bytes: dl.oldBytes, severity: .medium, action: .reveal(dl.location.url)))
        }

        // 6. Local snapshots when space is low.
        if !m.snapshots.isEmpty, freeFraction < 0.15 {
            let cmd = "tmutil thinlocalsnapshots / 50000000000 4"
            recs.append(Recommendation(
                id: "snapshots", title: "Thin Time Machine local snapshots",
                rationale: "\(m.snapshots.count) local snapshots exist; they count as purgeable and macOS deletes them when space is needed. To force: `\(cmd)`.",
                bytes: nil, severity: .medium, action: .copy(cmd)))
        }

        // 7. All good, or fill up with smaller wins.
        if recs.isEmpty, freeFraction > 0.25 {
            return [Recommendation(
                id: "ok", title: "You're in good shape",
                rationale: "\(Int(freeFraction * 100))% of your disk is free and nothing large is waiting to be cleaned.",
                bytes: nil, severity: .low, action: .none)]
        }
        if recs.count < 3 {
            let small = m.states.filter { $0.location.countsAsReclaimable && !used.contains($0.id) && $0.bytes > 500_000_000 }
                .sorted { $0.bytes > $1.bytes }
            for s in small.prefix(3 - recs.count) {
                recs.append(Recommendation(
                    id: s.id, title: "Clean \(s.location.title) (frees ~\(Fmt.bytes(s.bytes)))",
                    rationale: s.location.cleanHint, bytes: s.bytes, severity: .low, action: action(for: s)))
                used.insert(s.id)
            }
        }
        if recs.count < 3, let big = m.states(in: .content).max(by: { $0.bytes < $1.bytes }), big.bytes > GB {
            recs.append(Recommendation(
                id: "content-" + big.id, title: "Review \(big.location.title) (\(Fmt.bytes(big.bytes)))",
                rationale: "Your largest content folder; Spaceworthy won't touch it, but you might find things to archive.",
                bytes: big.bytes, severity: .low, action: .reveal(big.location.url)))
        }

        return Array(recs.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
            .prefix(8))
    }
}
