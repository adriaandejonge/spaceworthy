import Foundation

/// Sizes directory trees. All functions are synchronous and meant to run off the main actor.
enum Scanner {
    static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
        .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey,
    ]

    private final class Counter: @unchecked Sendable { var value = 0 }

    /// Walks `root` (including package contents, hidden files), skipping symlinks and
    /// continuing past permission errors. Stops after `timeLimit` seconds and marks the result partial.
    static func size(
        of root: URL,
        timeLimit: TimeInterval = 20,
        trackOld: Bool = false,
        trackNodeModules: Bool = false,
        keepAllChildren: Bool = false,
        progress: @escaping @Sendable (Int64) -> Void
    ) -> ScanResult {
        let start = Date()
        var result = ScanResult()
        let fm = FileManager()

        // Unreadable root => no access (e.g. TCC-protected without Full Disk Access).
        do { _ = try fm.contentsOfDirectory(atPath: root.path) } catch {
            result.noAccess = true
            result.duration = Date().timeIntervalSince(start)
            return result
        }

        let errors = Counter()
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in errors.value += 1; return true }
        ) else {
            result.noAccess = true
            return result
        }

        let keySet = Set(keys)
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let deadline = start.addingTimeInterval(timeLimit)
        var lastReport = start
        var counter = 0
        var currentChild: String?
        var childSizes: [String: Int64] = [:]
        var childLatest: [String: Date] = [:]
        var nodeModulesLevel: Int?
        var done = false

        while !done {
            autoreleasepool {
                for _ in 0..<2000 {
                    guard let url = en.nextObject() as? URL else { done = true; return }
                    let level = en.level
                    if level == 1 { currentChild = url.lastPathComponent }
                    if let l = nodeModulesLevel, level <= l { nodeModulesLevel = nil }

                    guard let rv = try? url.resourceValues(forKeys: keySet) else {
                        errors.value += 1
                        continue
                    }
                    if rv.isSymbolicLink == true { continue }

                    if keepAllChildren, let c = currentChild, let d = rv.contentModificationDate,
                       d > (childLatest[c] ?? .distantPast) { childLatest[c] = d }

                    if trackNodeModules, nodeModulesLevel == nil, rv.isDirectory == true,
                       level <= 4, url.lastPathComponent == "node_modules" {
                        nodeModulesLevel = level
                    }

                    if rv.isRegularFile == true {
                        let s = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                        result.bytes += s
                        result.fileCount += 1
                        if let c = currentChild { childSizes[c, default: 0] += s }
                        if nodeModulesLevel != nil { result.nodeModulesBytes += s }
                        if trackOld, let d = rv.contentModificationDate, d < cutoff { result.oldBytes += s }
                    }

                    counter += 1
                    if counter % 256 == 0 {
                        let now = Date()
                        if now > deadline { result.partial = true; done = true; return }
                        if now.timeIntervalSince(lastReport) > 0.25 {
                            progress(result.bytes)
                            lastReport = now
                        }
                    }
                }
            }
        }

        result.unreadable = errors.value
        // Nothing readable at all (e.g. TCC-protected app containers): report as no access rather than 0 bytes.
        if result.fileCount == 0, result.unreadable > 0 { result.noAccess = true }
        if keepAllChildren {
            result.allChildren = childSizes
            result.childLatest = childLatest
        }
        result.children = childSizes
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { ChildSize(name: $0.key, url: root.appendingPathComponent($0.key), bytes: $0.value) }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Number of top-level items in a directory (including hidden).
    static func itemCount(in url: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
    }

    /// Moves every top-level item inside `url` to the Trash. Never hard-deletes.
    static func trashContents(of url: URL) -> (moved: Int, failed: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) else {
            return (0, 0)
        }
        var moved = 0, failed = 0
        for item in items {
            do { try fm.trashItem(at: item, resultingItemURL: nil); moved += 1 } catch { failed += 1 }
        }
        return (moved, failed)
    }

    /// Runs a command; returns stdout+stderr, or nil if it fails to launch or exceeds `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        exec(path, args, timeout: timeout).map { $0.out + $0.err }
    }
}

// MARK: - Processes

struct ProcessOutput: Sendable {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
}

extension Scanner {
    /// Runs a process with separate stdout/stderr; nil on launch failure or timeout (the process is killed).
    static func exec(_ path: String, _ args: [String], timeout: TimeInterval) -> ProcessOutput? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let group = DispatchGroup()
        final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
        let box = Box()
        group.enter()
        DispatchQueue.global().async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            p.terminate()
            _ = group.wait(timeout: .now() + 1)
            return nil
        }
        _ = group.wait(timeout: .now() + 2)
        return ProcessOutput(status: p.terminationStatus,
                             out: String(data: box.out, encoding: .utf8) ?? "",
                             err: String(data: box.err, encoding: .utf8) ?? "")
    }

    static func git(_ dir: URL, _ args: [String], timeout: TimeInterval = 5) -> ProcessOutput? {
        exec("/usr/bin/git", ["-C", dir.path] + args, timeout: timeout)
    }
}

// MARK: - Worktrees

extension Scanner {
    /// Lists worktree folders under `<repo>/.claude/worktrees` with sizes from a scan (git details not yet loaded).
    static func worktrees(in dir: URL, repo: URL, sizes: [String: Int64], latest: [String: Date] = [:]) -> [WorktreeInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> WorktreeInfo? in
            let wt = dir.appendingPathComponent(name)
            guard Locations.isDirectory(wt) else { return nil }
            return WorktreeInfo(name: name, url: wt, repo: repo, bytes: sizes[name] ?? 0, modified: latest[name] ?? lastModified(wt))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    static func defaultBranch(of repo: URL) -> String {
        if let o = git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]), o.ok {
            let s = o.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = s.firstIndex(of: "/") { return String(s[s.index(after: slash)...]) }
            if !s.isEmpty { return s }
        }
        for b in ["main", "master"] {
            if let o = git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/" + b]), o.ok { return b }
        }
        return "main"
    }

    /// Fills in git details for each worktree, several at a time; each git call has a 5 s timeout.
    static func loadGitDetails(_ list: [WorktreeInfo], repo: URL) -> [WorktreeInfo] {
        let def = defaultBranch(of: repo)
        let mergedOut = git(repo, ["branch", "--merged", def, "--format=%(refname:short)"])
        let merged: Set<String>? = mergedOut.flatMap { $0.ok ? Set($0.out.split(separator: "\n").map(String.init)) : nil }

        final class Results: @unchecked Sendable {
            var items: [WorktreeInfo]
            let lock = NSLock()
            init(_ i: [WorktreeInfo]) { items = i }
        }
        let results = Results(list)
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            var w = list[i]
            w.defaultBranch = def
            let dir = w.url
            if let o = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]), o.ok {
                let b = o.out.trimmingCharacters(in: .whitespacesAndNewlines)
                w.detached = (b == "HEAD")
                w.branch = w.detached ? "detached" : b
            }
            if let o = git(dir, ["log", "-1", "--format=%ct"]), o.ok,
               let t = TimeInterval(o.out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                w.lastCommit = Date(timeIntervalSince1970: t)
            }
            if let o = git(dir, ["status", "--porcelain"]), o.ok {
                w.dirty = !o.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if w.detached {
                // Commits reachable only from this detached HEAD.
                if let o = git(dir, ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"]), o.ok {
                    w.unpushed = Int(o.out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else if w.branch != nil {
                if let o = git(dir, ["rev-list", "--count", "@{upstream}..HEAD"]) {
                    w.hasUpstream = o.ok
                    w.unpushed = o.ok ? Int(o.out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                }
                if let merged, let b = w.branch { w.merged = b != def && merged.contains(b) }
            }
            w.gitLoaded = w.branch != nil
            results.lock.lock()
            results.items[i] = w
            results.lock.unlock()
        }
        return results.items
    }

    /// Removes worktrees with git (never FileManager), prunes once, optionally deletes their branches.
    static func removeWorktrees(_ items: [WorktreeInfo], repo: URL, deleteBranches: Bool) -> RemovalOutcome {
        var r = RemovalOutcome()
        for w in items {
            guard let o = git(repo, ["worktree", "remove", "--force", w.url.path], timeout: 120) else {
                r.errors.append("\(w.name): git timed out")
                continue
            }
            if o.ok {
                r.removed += 1
                r.bytesFreed += w.bytes
                if deleteBranches, let b = w.deletableBranch {
                    if let d = git(repo, ["branch", "-D", b]), d.ok { r.branchesDeleted += 1 }
                    else { r.errors.append("\(w.name): couldn't delete branch \(b)") }
                }
            } else {
                r.errors.append("\(w.name): " + o.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let o = git(repo, ["worktree", "prune"], timeout: 30), !o.ok {
            r.errors.append("worktree prune: " + o.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }

    /// Latest modification date among a folder and its top-level entries.
    static func lastModified(_ url: URL) -> Date? {
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        var latest = (try? url.resourceValues(forKeys: key))?.contentModificationDate
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(key), options: [])) ?? []
        for item in items {
            if let d = (try? item.resourceValues(forKeys: key))?.contentModificationDate,
               d > (latest ?? .distantPast) { latest = d }
        }
        return latest
    }

    /// All top-level items of a folder with sizes from a scan.
    static func items(in dir: URL, sizes: [String: Int64], latest: [String: Date] = [:]) -> [ItemInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0 != ".DS_Store" }.map { name in
            let u = dir.appendingPathComponent(name)
            return ItemInfo(name: name, url: u, bytes: sizes[name] ?? 0, modified: latest[name] ?? lastModified(u))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Moves the given items to the Trash. Never hard-deletes.
    static func trash(_ urls: [URL]) -> (moved: Int, failed: Int) {
        var moved = 0, failed = 0
        for u in urls {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); moved += 1 } catch { failed += 1 }
        }
        return (moved, failed)
    }
}
