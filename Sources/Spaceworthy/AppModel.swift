import AppKit
import Foundation
import Observation
import SwiftUI

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()
    static let maxParallel = 4
    static let GB: Int64 = 1_000_000_000

    var states: [LocationState] = []
    var disk: DiskInfo?
    var snapshots: [String] = []
    var snapshotsLoaded = false
    var softwareUpdateText: String?
    var isScanning = false
    var lastScan: Date?
    var pendingClean: CleanRequest?
    var pendingRemoval: WorktreeRemovalRequest?
    var resultMessage: String?
    var statusMessage: String?
    var scrollRequest: String?
    var tab: AppTab = .overview

    // UI state (kept here: SwiftUI's @State macro plugin is not shipped with Command Line Tools).
    var collapsedSections: Set<String> = []
    var expandedRows: Set<String> = []
    var groupExpanded: [String: Bool] = [:]
    var worktreeFilter: [String: WorktreeFilter] = [:]
    var worktreeSort: [String: (WorktreeSort, Bool)] = [:]
    var selectedWorktrees: Set<String> = []
    var selectedJobs: Set<String> = []

    func sectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !self.collapsedSections.contains(id) },
                set: { if $0 { self.collapsedSections.remove(id) } else { self.collapsedSections.insert(id) } })
    }

    func toggleRow(_ id: String) {
        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
    }

    func groupBinding(_ s: LocationState) -> Binding<Bool> {
        Binding(get: { self.groupExpanded[s.id] ?? (s.bytes > Self.GB) },
                set: { self.groupExpanded[s.id] = $0 })
    }

    func toggle(_ id: String, in set: ReferenceWritableKeyPath<AppModel, Set<String>>) {
        if self[keyPath: set].contains(id) { self[keyPath: set].remove(id) } else { self[keyPath: set].insert(id) }
    }

    // MARK: Derived

    func states(in category: LocationCategory) -> [LocationState] {
        states.filter { $0.location.category == category }
    }

    /// Display order for every section: finished rows by size (largest first), then rows still scanning,
    /// then "no access" rows. Recomputed on every change, so rows re-sort live as results land.
    func sortedStates(in category: LocationCategory) -> [LocationState] {
        states(in: category).sorted { a, b in
            let ra = a.sortRank, rb = b.sortRank
            if ra != rb { return ra < rb }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.location.title < b.location.title
        }
    }

    func state(_ id: String) -> LocationState? { states.first { $0.id == id } }

    var worktreeStates: [LocationState] { states.filter { $0.location.worktreeRepo != nil } }
    var allWorktrees: [WorktreeInfo] { worktreeStates.flatMap(\.worktrees) }

    var claudeTotal: Int64 { states(in: .claude).reduce(0) { $0 + $1.bytes } }

    /// Job folders not touched for a week (safe to trash).
    var oldJobBytes: Int64 {
        (state("claudeJobs")?.items ?? []).filter { ($0.modified ?? .distantFuture) < Date().addingTimeInterval(-7 * 86_400) }
            .reduce(0) { $0 + $1.bytes }
    }

    /// Bytes in reclaimable locations, not double-counting nested locations.
    /// Worktree groups count only worktrees whose verdict is "Safe to remove".
    var reclaimableBytes: Int64 {
        let counted = states.filter { $0.location.countsAsReclaimable }
        let paths = counted.map { $0.location.url.path }
        return counted.reduce(0) { sum, s in
            let p = s.location.url.path
            if paths.contains(where: { $0 != p && p.hasPrefix($0 + "/") }) { return sum }
            return sum + (s.location.worktreeRepo != nil ? s.safeWorktreeBytes : s.bytes)
        }
    }

    var recommendations: [Recommendation] { Recommendations.build(self) }

    // MARK: Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        refreshDisk()

        let locations = await Task.detached(priority: .userInitiated) { Locations.all() }.value
        let existing = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        states = locations.map { existing[$0.id] ?? LocationState(location: $0) }

        async let system: Void = loadSystemInfo()
        // Privacy-protected folders last: their first access may block on a macOS permission prompt.
        await scan(states.filter { !$0.location.isPrivacyProtected } + states.filter { $0.location.isPrivacyProtected })
        await system

        refreshDisk()
        lastScan = Date()
        isScanning = false
    }

    func scan(_ list: [LocationState]) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for s in list {
                if running >= Self.maxParallel {
                    _ = await group.next()
                    running -= 1
                }
                group.addTask { await self.scanOne(s) }
                running += 1
            }
        }
    }

    func scanOne(_ s: LocationState) async {
        s.generation += 1
        let gen = s.generation
        s.isScanning = true
        s.bytes = 0
        let loc = s.location
        let perItem = loc.worktreeRepo != nil || loc.id == "claudeJobs"
        let result = await Task.detached(priority: .utility) { () -> ScanResult in
            // Per-item locations get a longer cap: removal decisions need complete per-item sizes.
            var r = Scanner.size(of: loc.url, timeLimit: perItem ? 120 : 20, trackOld: loc.trackOld,
                                 trackNodeModules: loc.trackNodeModules, keepAllChildren: perItem) { bytes in
                Task { @MainActor in
                    if s.generation == gen, s.isScanning { s.bytes = bytes }
                }
            }
            if let repo = loc.worktreeRepo {
                r.worktrees = Scanner.worktrees(in: loc.url, repo: repo, sizes: r.allChildren, latest: r.childLatest)
            } else if loc.id == "claudeJobs" {
                r.items = Scanner.items(in: loc.url, sizes: r.allChildren, latest: r.childLatest)
            }
            r.allChildren = [:]
            return r
        }.value
        guard s.generation == gen else { return }
        s.apply(result)

        if let repo = loc.worktreeRepo, !s.worktrees.isEmpty {
            s.gitLoading = true
            let list = s.worktrees
            let detailed = await Task.detached(priority: .utility) {
                Scanner.loadGitDetails(list, repo: repo)
            }.value
            guard s.generation == gen else { return }
            s.worktrees = detailed
            s.gitLoading = false
        }
    }

    func refreshDisk() {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return }
        disk = DiskInfo(
            name: v.volumeName ?? "Macintosh HD",
            total: Int64(v.volumeTotalCapacity ?? 0),
            available: Int64(v.volumeAvailableCapacity ?? 0),
            importantAvailable: v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        )
    }

    func loadSystemInfo() async {
        let (snaps, sw) = await Task.detached(priority: .utility) { () -> ([String], String?) in
            let out = Scanner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 5) ?? ""
            let snaps = out.split(separator: "\n").compactMap { line -> String? in
                guard let r = line.range(of: "com.apple.TimeMachine.") else { return nil }
                let stamp = line[r.upperBound...].replacingOccurrences(of: ".local", with: "")
                // 2026-10-24-123456 -> 2026-10-24 12:34
                let parts = stamp.split(separator: "-")
                if parts.count == 4, parts[3].count >= 4 {
                    let t = parts[3]
                    return "\(parts[0])-\(parts[1])-\(parts[2]) \(t.prefix(2)):\(t.dropFirst(2).prefix(2))"
                }
                return stamp
            }
            let sw = Scanner.run("/usr/sbin/softwareupdate", ["--list", "--no-scan"], timeout: 3)
            return (snaps, sw?.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        snapshots = snaps
        snapshotsLoaded = true
        softwareUpdateText = (sw?.isEmpty ?? true) ? nil : sw
    }

    // MARK: Simple actions

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied to clipboard: \(text)"
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Expands and scrolls to a Claude Code row; worktree groups get the "Safe" filter.
    func show(_ id: String) {
        collapsedSections.remove(LocationCategory.claude.id)
        if let s = state(id), s.location.worktreeRepo != nil {
            groupExpanded[id] = true
            worktreeFilter[id] = .safe
        } else {
            expandedRows.insert(id)
        }
        scrollRequest = id
    }

    // MARK: Clean (Trash)

    func requestClean(_ id: String) {
        guard let s = state(id) else { return }
        let loc = s.location
        pendingClean = CleanRequest(stateID: s.id, title: loc.title, itemCount: Scanner.itemCount(in: loc.url),
                                    bytes: s.bytes, hint: loc.cleanHint, isEmptyTrash: loc.actionKind == .emptyTrash)
    }

    func requestTrashSelectedJobs() {
        guard let s = state("claudeJobs") else { return }
        let items = s.items.filter { selectedJobs.contains($0.id) }
        guard !items.isEmpty else { return }
        pendingClean = CleanRequest(stateID: s.id, title: "selected Claude Code jobs", itemCount: items.count,
                                    bytes: items.reduce(0) { $0 + $1.bytes }, hint: s.location.cleanHint,
                                    isEmptyTrash: false, items: items.map(\.url))
    }

    func performClean(_ r: CleanRequest) {
        pendingClean = nil
        if let ex = r.exploreURL {
            let (moved, failed) = Scanner.trash(r.items ?? [])
            statusMessage = "Moved \(moved) item\(moved == 1 ? "" : "s") from \(ex.lastPathComponent) to the Trash"
                + (failed > 0 ? " (\(failed) in use or protected, skipped)." : ".")
            ExploreModel.shared.invalidate(ex)
            refreshDisk()
            return
        }
        guard let s = state(r.stateID) else { return }
        if r.isEmptyTrash {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            if let err {
                statusMessage = "Couldn't empty the Trash: \(err[NSAppleScript.errorMessage] ?? "unknown error")"
            } else {
                statusMessage = "Emptied the Trash."
            }
        } else {
            let (moved, failed) = r.items.map(Scanner.trash) ?? Scanner.trashContents(of: s.location.url)
            statusMessage = "Moved \(moved) item\(moved == 1 ? "" : "s") from \(s.location.title) to the Trash"
                + (failed > 0 ? " (\(failed) in use or protected, skipped)." : ".")
            if r.items != nil { selectedJobs.removeAll() }
        }
        Task {
            await scanOne(s)
            if let trash = state("trash"), trash.id != s.id { await scanOne(trash) }
            refreshDisk()
        }
    }

    // MARK: Worktree removal (git only)

    func visibleWorktrees(_ s: LocationState) -> [WorktreeInfo] {
        let filter = worktreeFilter[s.id] ?? .all
        let (key, asc) = worktreeSort[s.id] ?? (.size, false)
        let list = s.worktrees.filter(filter.matches)
        let sorted: [WorktreeInfo]
        switch key {
        case .size: sorted = list.sorted { $0.bytes < $1.bytes }
        case .age: sorted = list.sorted { ($0.activity ?? .distantPast) < ($1.activity ?? .distantPast) }
        case .name: sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return asc ? sorted : sorted.reversed()
    }

    func setSort(_ key: WorktreeSort, for s: LocationState) {
        let (cur, asc) = worktreeSort[s.id] ?? (.size, false)
        worktreeSort[s.id] = cur == key ? (key, !asc) : (key, key == .name)
    }

    func selected(in s: LocationState) -> [WorktreeInfo] {
        s.worktrees.filter { selectedWorktrees.contains($0.id) }
    }

    func requestRemoval(_ s: LocationState) {
        guard let repo = s.location.worktreeRepo else { return }
        let items = selected(in: s)
        guard !items.isEmpty else { return }
        pendingRemoval = WorktreeRemovalRequest(stateID: s.id, repo: repo, items: items)
    }

    func performRemoval(_ r: WorktreeRemovalRequest) {
        pendingRemoval = nil
        guard let s = state(r.stateID) else { return }
        let items = r.effective
        let repo = r.repo
        let deleteBranches = r.deleteBranches
        statusMessage = "Removing \(items.count) worktree\(items.count == 1 ? "" : "s") from \(s.repoName)…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Scanner.removeWorktrees(items, repo: repo, deleteBranches: deleteBranches)
            }.value
            for w in items { selectedWorktrees.remove(w.id) }
            var msg = "Removed \(outcome.removed) of \(items.count) worktree\(items.count == 1 ? "" : "s") from \(s.repoName), freeing about \(Fmt.bytes(outcome.bytesFreed))."
            if deleteBranches { msg += " Deleted \(outcome.branchesDeleted) branch\(outcome.branchesDeleted == 1 ? "" : "es")." }
            if !outcome.errors.isEmpty {
                msg += "\n\nErrors:\n" + outcome.errors.prefix(10).joined(separator: "\n")
                if outcome.errors.count > 10 { msg += "\n…and \(outcome.errors.count - 10) more" }
            }
            statusMessage = nil
            resultMessage = msg
            await scanOne(s)
            refreshDisk()
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case overview = "Overview", explore = "Explore"
    var id: String { rawValue }
}

extension AppModel {
    /// Clean… from the Explore tab: trashes the folder's contents (for cache containers) or the item itself.
    func requestExploreClean(_ node: ExploreNode) {
        let ex = ExploreModel.shared
        let urls: [URL]
        if node.isDirectory, ex.trashesContents(node.url, app: self) {
            urls = (try? FileManager.default.contentsOfDirectory(at: node.url, includingPropertiesForKeys: nil, options: [])) ?? []
        } else {
            urls = [node.url]
        }
        let hint = urls.count == 1 && urls.first == node.url
            ? "Moves \(node.name) to the Trash. It regenerates when the owning tool needs it again."
            : "Moves the contents of \(node.name) to the Trash; the folder itself stays."
        pendingClean = CleanRequest(stateID: "explore", title: node.name, itemCount: urls.count, bytes: node.bytes ?? 0,
                                    hint: hint, isEmptyTrash: false, items: urls, exploreURL: node.url)
    }

    /// Worktree removal for one worktree folder (from Explore); falls back to showing its group.
    func requestRemoval(worktreePath path: String) {
        for s in worktreeStates {
            if let w = s.worktrees.first(where: { $0.url.path == path }), let repo = s.location.worktreeRepo {
                pendingRemoval = WorktreeRemovalRequest(stateID: s.id, repo: repo, items: [w])
                return
            }
        }
        if let s = worktreeStates.first(where: { path.hasPrefix($0.location.url.path) }) {
            tab = .overview
            show(s.id)
        }
    }
}
