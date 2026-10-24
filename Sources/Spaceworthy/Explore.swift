import AppKit
import Foundation
import Observation
import SwiftUI

enum SafetyLabel: Int, CaseIterable, Identifiable {
    case safe, content, system, unknown
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .safe: "Safe to clean"
        case .content: "Your content"
        case .system: "System / app data"
        case .unknown: "Unknown"
        }
    }

    var explanation: String {
        switch self {
        case .safe: "Caches, temp and build output that regenerate; can be moved to the Trash."
        case .content: "Your own files. Reveal only — Spaceworthy never offers to remove these."
        case .system: "Managed by macOS or an app. Reveal only; uninstall the owning app to reclaim."
        case .unknown: "Not recognised. Reveal only — look before you delete."
        }
    }

    var symbol: String {
        switch self {
        case .safe: "leaf.fill"
        case .content: "shield.fill"
        case .system: "gearshape.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .content: .blue
        case .system: .orange
        case .unknown: .gray
        }
    }
}

@Observable @MainActor
final class ExploreNode: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    var bytes: Int64?
    var itemCount: Int?
    var modified: Date?
    var isSizing = false
    var partial = false
    var noAccess = false
    var children: [ExploreNode]?
    var isLoadingChildren = false
    var expanded = false
    weak var parent: ExploreNode?

    nonisolated var id: String { url.path }

    init(url: URL, name: String? = nil, isDirectory: Bool, isHidden: Bool, modified: Date?) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.modified = modified
    }

    var sortedChildren: [ExploreNode] {
        // Sized first (largest first), then still sizing, then "no access".
        func rank(_ n: ExploreNode) -> Int { n.noAccess ? 2 : (n.isSizing || n.bytes == nil) ? 1 : 0 }
        return (children ?? []).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if (a.bytes ?? 0) != (b.bytes ?? 0) { return (a.bytes ?? 0) > (b.bytes ?? 0) }
            return a.name < b.name
        }
    }

    /// Own size, or the sum of sized children (for roots that aren't sized as a whole).
    var effectiveBytes: Int64 {
        bytes ?? (children ?? []).reduce(0) { $0 + ($1.bytes ?? 0) }
    }
}

enum ExploreRoot: String, CaseIterable, Identifiable {
    case home = "Home", disk = "/", users = "/Users", library = "/Library", apps = "/Applications", userLibrary = "~/Library"
    var id: String { rawValue }

    var url: URL {
        switch self {
        case .home: Locations.home
        case .disk: URL(fileURLWithPath: "/")
        case .users: URL(fileURLWithPath: "/Users")
        case .library: URL(fileURLWithPath: "/Library")
        case .apps: URL(fileURLWithPath: "/Applications")
        case .userLibrary: Locations.home.appendingPathComponent("Library")
        }
    }
}

@Observable @MainActor
final class ExploreModel {
    static let shared = ExploreModel()

    var root: ExploreNode?
    var activeSizing = 0
    /// Session cache: path -> (bytes, items, partial, noAccess).
    private var sizeCache: [String: (Int64, Int, Bool, Bool)] = [:]

    var isBusy: Bool { activeSizing > 0 || (root?.isLoadingChildren ?? false) }

    nonisolated static let diskRootChildren = ["/System", "/Library", "/Applications", "/Users", "/private", "/opt", "/usr/local"]

    func open(_ url: URL) {
        let node = ExploreNode(url: url, name: url.path == Locations.home.path ? "Home (~)" : nil,
                               isDirectory: true, isHidden: false, modified: nil)
        node.expanded = true
        root = node
        Task { await loadChildren(node) }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = root?.url
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func toggle(_ node: ExploreNode) {
        guard node.isDirectory else { return }
        node.expanded.toggle()
        if node.expanded, node.children == nil { Task { await loadChildren(node) } }
    }

    /// Flattened visible rows (depth-first, size-sorted).
    func visibleRows() -> [(ExploreNode, Int)] {
        guard let root else { return [] }
        var out: [(ExploreNode, Int)] = []
        func walk(_ n: ExploreNode, _ depth: Int) {
            for c in n.sortedChildren {
                out.append((c, depth))
                if c.expanded { walk(c, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    func loadChildren(_ node: ExploreNode) async {
        node.isLoadingChildren = true
        let url = node.url
        let listed = await Task.detached(priority: .userInitiated) { () -> [(URL, Bool, Bool, Date?, Int64?)] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey,
                                          .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            let urls: [URL]
            if url.path == "/" {
                urls = ExploreModel.diskRootChildren.map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            } else {
                urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
            }
            return urls.compactMap { u in
                let rv = try? u.resourceValues(forKeys: Set(keys))
                if rv?.isSymbolicLink == true { return nil }
                let isDir = rv?.isDirectory ?? false
                let hidden = (rv?.isHidden ?? false) || u.lastPathComponent.hasPrefix(".")
                let size = isDir ? nil : Int64(rv?.totalFileAllocatedSize ?? rv?.fileAllocatedSize ?? 0)
                return (u, isDir, hidden, rv?.contentModificationDate, size)
            }
        }.value

        let nodes = listed.map { (u, isDir, hidden, mod, size) -> ExploreNode in
            let n = ExploreNode(url: u, isDirectory: isDir, isHidden: hidden, modified: mod)
            if let size { n.bytes = size; n.itemCount = 1 }
            n.parent = node
            if let c = sizeCache[u.path] { n.bytes = c.0; n.itemCount = c.1; n.partial = c.2; n.noAccess = c.3 }
            return n
        }
        node.children = nodes
        node.isLoadingChildren = false
        await size(nodes.filter { $0.isDirectory && $0.bytes == nil })
    }

    private func size(_ nodes: [ExploreNode]) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for n in nodes {
                if running >= 4 { _ = await group.next(); running -= 1 }
                group.addTask { await self.sizeOne(n) }
                running += 1
            }
        }
    }

    func sizeOne(_ n: ExploreNode) async {
        n.isSizing = true
        activeSizing += 1
        let url = n.url
        let r = await Task.detached(priority: .utility) {
            Scanner.size(of: url, timeLimit: 60) { b in
                Task { @MainActor in if n.isSizing { n.bytes = b } }
            }
        }.value
        n.isSizing = false
        n.bytes = r.bytes
        n.itemCount = r.fileCount
        n.partial = r.partial
        n.noAccess = r.noAccess
        sizeCache[url.path] = (r.bytes, r.fileCount, r.partial, r.noAccess)
        activeSizing -= 1
    }

    /// Re-sizes a node and its ancestors after something inside it was removed.
    func invalidate(_ url: URL) {
        let p = url.path
        for key in sizeCache.keys where key == p || p.hasPrefix(key + "/") || key.hasPrefix(p + "/") {
            sizeCache[key] = nil
        }
        guard let root else { return }
        var stack = [root]
        var toReload: [ExploreNode] = []
        while let n = stack.popLast() {
            if n.url.path == p || p.hasPrefix(n.url.path + "/") {
                if n !== root, n.isDirectory { toReload.append(n) }
                stack.append(contentsOf: n.children ?? [])
            }
        }
        // Reload the deepest affected parent's children, then resize ancestors.
        Task {
            if let parent = toReload.last(where: { $0.url.path != p }) ?? (p.hasPrefix(root.url.path + "/") ? root : nil) {
                await loadChildren(parent)
            }
            for n in toReload where n.url.path != p { await sizeOne(n) }
        }
    }

    // MARK: Classification

    static let cacheNames: Set<String> = ["Caches", "caches", "cache", ".cache", "Cache", "tmp", ".tmp", "DerivedData",
                                          "node_modules", "__pycache__", ".venv", ".next", ".pytest_cache", ".mypy_cache"]
    static let buildNames: Set<String> = ["build", "dist", "target", ".build"]
    static let projectMarkers = ["package.json", "Cargo.toml", "Package.swift", "build.gradle", "build.gradle.kts",
                                 "pom.xml", "pyproject.toml", "Makefile", "go.mod", ".git"]

    func label(for url: URL, app: AppModel) -> SafetyLabel {
        let p = url.path
        let home = Locations.home.path
        func inside(_ base: String) -> Bool { p == base || p.hasPrefix(base + "/") }

        // Claude worktrees and catalog locations.
        if Self.isWorktree(url) || p.hasSuffix("/.claude/worktrees") { return .safe }
        for s in app.states where s.location.category == .safe || (s.location.category == .claude && s.location.actionKind != .revealOnly) {
            if inside(s.location.url.path) { return .safe }
        }

        let contentRoots = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Library/Mail", "Library/Messages",
                            "Library/Mobile Documents", "Downloads"].map { home + "/" + $0 }
        let inMedia = contentRoots.contains(where: inside)

        // Cache-ish names (not inside photo/music libraries and other personal content).
        if !inMedia {
            let comps = url.pathComponents
            if comps.contains(where: { Self.cacheNames.contains($0) }) || p.contains("/.gradle/caches") { return .safe }
            if let i = comps.lastIndex(where: { Self.buildNames.contains($0) }), i > 1 {
                let parent = NSString.path(withComponents: Array(comps[..<i]))
                let fm = FileManager.default
                let markers = comps[i] == "target" ? ["Cargo.toml", "pom.xml"] : Self.projectMarkers
                if markers.contains(where: { fm.fileExists(atPath: parent + "/" + $0) }) { return .safe }
            }
        }

        if inMedia { return .content }
        for base in ["projects", "Developer", "code", "src"].map({ home + "/" + $0 }) where inside(base) { return .content }

        let systemRoots = [home + "/Library", "/Library", "/System", "/private", "/usr", "/opt", "/Applications",
                           home + "/Applications", "/bin", "/sbin", "/cores"]
        if systemRoots.contains(where: inside) { return .system }
        return .unknown
    }

    /// A direct child of `<repo>/.claude/worktrees`.
    static func isWorktree(_ url: URL) -> Bool {
        url.deletingLastPathComponent().path.hasSuffix("/.claude/worktrees")
    }

    /// Folders whose contents (not the folder itself) should be trashed.
    func trashesContents(_ url: URL, app: AppModel) -> Bool {
        let containers: Set<String> = ["Caches", "caches", "cache", ".cache", "Cache", "tmp", "T", "C", "DerivedData"]
        return containers.contains(url.lastPathComponent) || app.states.contains { $0.location.url.path == url.path }
    }
}
