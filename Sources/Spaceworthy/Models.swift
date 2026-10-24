import Foundation
import Observation
import SwiftUI

enum LocationCategory: String, CaseIterable, Identifiable, Sendable {
    case safe, claude, content, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: "Safe to clean"
        case .claude: "Claude Code"
        case .content: "Your content"
        case .system: "System"
        }
    }

    var subtitle: String {
        switch self {
        case .safe: "Caches, temp files and build artifacts that regenerate on demand"
        case .claude: "Agent worktrees, job data and caches left behind by Claude Code"
        case .content: "Read-only — review these yourself in Finder"
        case .system: "Managed by macOS"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "leaf"
        case .claude: "sparkles"
        case .content: "person.crop.square"
        case .system: "gearshape"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .claude: .purple
        case .content: .blue
        case .system: .orange
        }
    }
}

enum ActionKind: Sendable, Equatable {
    /// Contents can be moved to the Trash.
    case trash
    /// The Trash itself: emptied via Finder.
    case emptyTrash
    /// Only open in Finder.
    case revealOnly
    /// Show a terminal command the user can copy.
    case command
    /// Informational system location.
    case systemInfo
}

struct Location: Identifiable, Sendable {
    let id: String
    let title: String
    let url: URL
    let category: LocationCategory
    let summary: String
    let cleanHint: String
    let actionKind: ActionKind
    var command: String? = nil
    var symbol: String = "folder"
    /// Track bytes of files older than 30 days (Downloads).
    var trackOld = false
    /// Track node_modules found within depth 4 (projects).
    var trackNodeModules = false
    /// Part of a pending macOS update/installer.
    var isInstaller = false
    /// `url` is `<repo>/.claude/worktrees`; each child is a git worktree.
    var worktreeRepo: URL? = nil

    /// Counts toward the "safely reclaimable" headline.
    var countsAsReclaimable: Bool {
        switch category {
        case .safe: true
        case .claude: actionKind != .revealOnly
        default: false
        }
    }

    /// Behind a macOS privacy prompt (TCC); scanned last so a pending prompt never stalls other rows.
    var isPrivacyProtected: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["Desktop", "Documents", "Downloads", ".Trash", "Library/Containers", "Library/Group Containers",
                         "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/Application Support/MobileSync",
                         "Pictures", "Movies", "Music"].map { home + "/" + $0 }
        return protected.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
    }

    var displayPath: String { Location.tilde(url.path) }

    static func tilde(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

struct ChildSize: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let url: URL
    let bytes: Int64
}

enum WorktreeVerdict: Int, Comparable, Sendable {
    case safe = 0, probablySafe = 1, unsaved = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .safe: "Safe to remove"
        case .probablySafe: "Probably safe"
        case .unsaved: "Has unsaved work"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .probablySafe: .yellow
        case .unsaved: .red
        }
    }
}

struct WorktreeInfo: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let repo: URL
    var bytes: Int64
    var modified: Date?

    // Filled in by git (nil = unknown).
    var gitLoaded = false
    var branch: String?
    var detached = false
    var lastCommit: Date?
    var dirty: Bool?
    var unpushed: Int?
    var hasUpstream: Bool?
    var merged: Bool?
    var defaultBranch: String?

    /// Most recent of last commit and directory modification.
    var activity: Date? {
        switch (lastCommit, modified) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        default: nil
        }
    }

    var ageDays: Double {
        guard let a = activity else { return 0 }
        return Date().timeIntervalSince(a) / 86_400
    }

    var isStale: Bool { ageDays > 7 }

    var verdict: WorktreeVerdict {
        guard gitLoaded, dirty == false else { return .unsaved }
        if merged == true { return .safe }
        if detached, unpushed == 0 { return .safe }
        if hasUpstream == true, unpushed == 0 { return .probablySafe }
        return .unsaved
    }

    /// Branch that may be deleted with `branch -D` (never the default branch or a detached HEAD).
    var deletableBranch: String? {
        guard !detached, let b = branch, b != "?", b != defaultBranch, b != "main", b != "master" else { return nil }
        return b
    }
}

/// A top-level child folder with size and modification date (used for ~/.claude/jobs).
struct ItemInfo: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let bytes: Int64
    let modified: Date?
}

struct ScanResult: Sendable {
    var bytes: Int64 = 0
    var fileCount = 0
    var unreadable = 0
    var partial = false
    var noAccess = false
    var duration: TimeInterval = 0
    var children: [ChildSize] = []
    var allChildren: [String: Int64] = [:]
    /// Newest modification date anywhere inside each top-level child (keepAllChildren only).
    var childLatest: [String: Date] = [:]
    var oldBytes: Int64 = 0
    var nodeModulesBytes: Int64 = 0
    var worktrees: [WorktreeInfo] = []
    var items: [ItemInfo] = []
}

@Observable @MainActor
final class LocationState: Identifiable {
    let location: Location
    nonisolated var id: String { location.id }

    var bytes: Int64 = 0
    var fileCount = 0
    var unreadable = 0
    var isScanning = false
    var hasScanned = false
    var partial = false
    var noAccess = false
    var duration: TimeInterval = 0
    var children: [ChildSize] = []
    var oldBytes: Int64 = 0
    var nodeModulesBytes: Int64 = 0
    var worktrees: [WorktreeInfo] = []
    var gitLoading = false
    var items: [ItemInfo] = []
    var generation = 0

    init(location: Location) { self.location = location }

    /// 0 = sized, 1 = still scanning, 2 = no access.
    var sortRank: Int { noAccess ? 2 : (isScanning || !hasScanned) ? 1 : 0 }

    var repoName: String { location.worktreeRepo?.lastPathComponent ?? location.title }

    func worktreeBytes(_ filter: (WorktreeInfo) -> Bool) -> Int64 {
        worktrees.filter(filter).reduce(0) { $0 + $1.bytes }
    }

    var safeWorktreeBytes: Int64 { worktreeBytes { $0.verdict == .safe } }

    func apply(_ r: ScanResult) {
        bytes = r.bytes
        fileCount = r.fileCount
        unreadable = r.unreadable
        partial = r.partial
        noAccess = r.noAccess
        duration = r.duration
        children = r.children
        oldBytes = r.oldBytes
        nodeModulesBytes = r.nodeModulesBytes
        worktrees = r.worktrees
        items = r.items
        isScanning = false
        hasScanned = true
    }
}

enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all = "All", safe = "Safe", older7 = "Older than 7 days", older30 = "Older than 30 days"
    var id: String { rawValue }

    func matches(_ w: WorktreeInfo) -> Bool {
        switch self {
        case .all: true
        case .safe: w.verdict == .safe
        case .older7: w.ageDays > 7
        case .older30: w.ageDays > 30
        }
    }
}

enum WorktreeSort: String { case size, age, name }

/// Pending in-app worktree removal; toggles are edited in the confirmation sheet.
@Observable @MainActor
final class WorktreeRemovalRequest: Identifiable {
    let id = UUID()
    let stateID: String
    let repo: URL
    let items: [WorktreeInfo]
    var includeUnsaved = false
    var deleteBranches = false

    init(stateID: String, repo: URL, items: [WorktreeInfo]) {
        self.stateID = stateID
        self.repo = repo
        self.items = items
    }

    var unsaved: [WorktreeInfo] { items.filter { $0.verdict == .unsaved } }
    var effective: [WorktreeInfo] { includeUnsaved ? items : items.filter { $0.verdict != .unsaved } }
    var effectiveBytes: Int64 { effective.reduce(0) { $0 + $1.bytes } }
}

struct RemovalOutcome: Sendable {
    var removed = 0
    var bytesFreed: Int64 = 0
    var branchesDeleted = 0
    var errors: [String] = []
}

struct DiskInfo: Sendable {
    var name: String
    var total: Int64
    var available: Int64
    var importantAvailable: Int64

    var purgeable: Int64 { max(0, importantAvailable - available) }
    var used: Int64 { max(0, total - max(available, importantAvailable)) }
    var freeFraction: Double { total > 0 ? Double(available) / Double(total) : 1 }
}

enum Severity: Int, Comparable, Sendable {
    case high = 0, medium = 1, low = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .green
        }
    }
}

enum RecommendationAction: Sendable {
    case clean(String)
    case reveal(URL)
    case copy(String)
    case openURL(URL, label: String)
    /// Scroll to a row in the Claude Code section (worktree group or jobs) and pre-filter it.
    case show(String, label: String)
    case none
}

struct Recommendation: Identifiable, Sendable {
    let id: String
    let title: String
    let rationale: String
    let bytes: Int64?
    let severity: Severity
    let action: RecommendationAction
}

struct CleanRequest: Identifiable {
    let id = UUID()
    let stateID: String
    let title: String
    let itemCount: Int
    let bytes: Int64
    let hint: String
    let isEmptyTrash: Bool
    /// When set, only these items are trashed (instead of the whole folder contents).
    var items: [URL]? = nil
    /// Set when the request comes from the Explore tab (that subtree is re-sized afterwards).
    var exploreURL: URL? = nil
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

enum Shell {
    static func quote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-~".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
