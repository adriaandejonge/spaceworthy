import Foundation

/// Catalog of locations Spaceworthy knows about. Only locations that exist on disk are returned.
enum Locations {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func expand(_ path: String) -> URL {
        var p = (path as NSString).expandingTildeInPath
        if p.hasPrefix("/var/") || p.hasPrefix("/tmp/") { p = "/private" + p }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return URL(fileURLWithPath: p).standardizedFileURL
    }

    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    /// The current user's `/private/var/folders/xx/yyyy/{T,C}` directories.
    static func userTempDirs() -> (temp: URL?, cache: URL?) {
        let t = expand(NSTemporaryDirectory())
        if t.lastPathComponent == "T", t.path.hasPrefix("/private/var/folders/") {
            let base = t.deletingLastPathComponent()
            return (t, base.appendingPathComponent("C"))
        }
        // Fallback: scan /private/var/folders/*/* for a directory owned by this user.
        let fm = FileManager.default
        let root = "/private/var/folders"
        for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for b in (try? fm.contentsOfDirectory(atPath: "\(root)/\(a)")) ?? [] {
                let base = "\(root)/\(a)/\(b)"
                let owner = (try? fm.attributesOfItem(atPath: base))?[.ownerAccountID] as? NSNumber
                if owner?.uint32Value == getuid(), fm.fileExists(atPath: base + "/T") {
                    return (URL(fileURLWithPath: base + "/T"), URL(fileURLWithPath: base + "/C"))
                }
            }
        }
        return (nil, nil)
    }

    /// Repos containing a non-empty `.claude/worktrees`, searched to depth 4 under common code roots.
    static func claudeWorktreeDirs() -> [URL] {
        let roots = ["~/projects", "~/Developer", "~/code", "~/src"].map(expand).filter(isDirectory)
        let fm = FileManager.default
        var found: [URL] = []
        let skip: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData", "Pods", "target", "dist", "worktrees"]
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         options: [], errorHandler: { _, _ in true }) else { continue }
            while let url = en.nextObject() as? URL {
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rv?.isDirectory == true, rv?.isSymbolicLink != true else { continue }
                let name = url.lastPathComponent
                if name == ".claude" {
                    let wt = url.appendingPathComponent("worktrees")
                    if isDirectory(wt), !((try? fm.contentsOfDirectory(atPath: wt.path)) ?? []).isEmpty {
                        found.append(wt)
                    }
                    en.skipDescendants()
                } else if skip.contains(name) || en.level >= 4 {
                    en.skipDescendants()
                }
            }
        }
        return found
    }

    static func all() -> [Location] {
        var list: [Location] = []

        func add(_ id: String, _ title: String, _ path: String, _ cat: LocationCategory, _ kind: ActionKind,
                 symbol: String, _ summary: String, hint: String, command: String? = nil,
                 trackOld: Bool = false, trackNodeModules: Bool = false) {
            list.append(Location(id: id, title: title, url: expand(path), category: cat, summary: summary,
                                 cleanHint: hint, actionKind: kind, command: command, symbol: symbol,
                                 trackOld: trackOld, trackNodeModules: trackNodeModules))
        }

        // MARK: Safe to clean
        let regen = "Apps rebuild these files on demand; expect slightly slower first launches."
        add("caches", "User caches", "~/Library/Caches", .safe, .trash, symbol: "archivebox",
            "Per-app caches for your account.", hint: regen)
        let tmp = userTempDirs()
        if let t = tmp.temp {
            add("tempT", "Temporary files", t.path, .safe, .trash, symbol: "clock.arrow.circlepath",
                "Your per-user temp directory (NSTemporaryDirectory).",
                hint: "Temp files are disposable; quit running apps first so they don't lose in-progress work.")
        }
        if let c = tmp.cache {
            add("tempC", "Per-user system cache", c.path, .safe, .trash, symbol: "clock.arrow.circlepath",
                "Caches macOS keeps per user in /var/folders.", hint: regen)
        }
        add("logs", "Logs", "~/Library/Logs", .safe, .trash, symbol: "doc.text",
            "Diagnostic and crash logs written by apps.", hint: "Logs are only needed for troubleshooting; new ones are written as needed.")
        add("trash", "Trash", "~/.Trash", .safe, .emptyTrash, symbol: "trash",
            "Items you already moved to the Trash.", hint: "Emptying the Trash permanently removes these items.")

        add("derivedData", "Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData", .safe, .trash, symbol: "hammer",
            "Xcode build intermediates and indexes.", hint: "Xcode rebuilds it on the next build (first build is slower).")
        add("xcArchives", "Xcode Archives", "~/Library/Developer/Xcode/Archives", .safe, .revealOnly, symbol: "archivebox.fill",
            "Archived app builds, including dSYMs.", hint: "Keep archives of shipped versions if you need to symbolicate crash reports.")
        add("deviceSupport", "iOS DeviceSupport", "~/Library/Developer/Xcode/iOS DeviceSupport", .safe, .trash, symbol: "iphone",
            "Debug symbols copied from connected devices.", hint: "Xcode re-copies symbols when the device is connected again.")
        add("simCaches", "Simulator caches", "~/Library/Developer/CoreSimulator/Caches", .safe, .trash, symbol: "iphone.gen3",
            "Caches used by the iOS Simulator.", hint: "Regenerated when simulators boot.")
        add("simDevices", "Simulator devices", "~/Library/Developer/CoreSimulator/Devices", .safe, .command, symbol: "iphone.gen3",
            "Installed simulator devices and their data.", hint: "Removes simulators for runtimes that are no longer installed.",
            command: "xcrun simctl delete unavailable")
        add("xcodeCache", "Xcode cache", "~/Library/Caches/com.apple.dt.Xcode", .safe, .trash, symbol: "hammer",
            "Xcode's download and documentation cache.", hint: regen)

        add("brew", "Homebrew cache", "~/Library/Caches/Homebrew", .safe, .command, symbol: "mug",
            "Downloaded bottles and source archives.", hint: "Homebrew re-downloads packages only when reinstalling.",
            command: "brew cleanup --prune=all")
        add("npm", "npm cache", "~/.npm/_cacache", .safe, .trash, symbol: "shippingbox",
            "npm's content-addressed package cache.", hint: "npm re-downloads packages on the next install.")
        add("bun", "Bun cache", "~/.bun/install/cache", .safe, .trash, symbol: "shippingbox",
            "Bun's package cache (separate from npm's).", hint: "Bun re-downloads packages on the next install.")
        add("bunglobal", "Bun global packages", "~/.bun/install/global", .safe, .revealOnly, symbol: "shippingbox",
            "Packages installed with `bun install -g`.", hint: "Uninstall with `bun remove -g <name>`; deleting the folder breaks those global commands.")
        add("dotcache", "~/.cache", "~/.cache", .safe, .trash, symbol: "shippingbox",
            "XDG cache used by many CLI tools (uv, huggingface, pre-commit…).", hint: "Tools re-download or rebuild what they need; ML model caches can be large to re-fetch.")
        add("pip", "pip cache", "~/Library/Caches/pip", .safe, .trash, symbol: "shippingbox",
            "Downloaded Python wheels.", hint: "pip re-downloads wheels on the next install.")
        add("gradle", "Gradle caches", "~/.gradle/caches", .safe, .trash, symbol: "shippingbox",
            "Gradle dependency and build caches.", hint: "Gradle re-downloads dependencies on the next build.")
        add("m2", "Maven repository", "~/.m2/repository", .safe, .revealOnly, symbol: "shippingbox",
            "Local Maven artifact repository.", hint: "Maven re-downloads artifacts; locally installed snapshots would be lost.")
        add("cargo", "Cargo registry", "~/.cargo/registry", .safe, .revealOnly, symbol: "shippingbox",
            "Downloaded crate sources and index.", hint: "Cargo re-downloads crates on the next build.")
        add("pnpm", "pnpm store", "~/Library/pnpm/store", .safe, .command, symbol: "shippingbox",
            "pnpm's global content-addressed store.", hint: "Prune removes packages not referenced by any project.",
            command: "pnpm store prune")
        add("yarn", "Yarn cache", "~/.yarn/cache", .safe, .trash, symbol: "shippingbox",
            "Yarn's offline package cache.", hint: "Yarn re-downloads packages on the next install.")
        add("gobuild", "Go build cache", "~/Library/Caches/go-build", .safe, .command, symbol: "shippingbox",
            "Compiled Go package cache.", hint: "Go rebuilds packages on the next build.", command: "go clean -cache")

        add("docker", "Docker data", "~/Library/Containers/com.docker.docker/Data", .safe, .command, symbol: "shippingbox.fill",
            "Docker Desktop's VM disk with images, containers and volumes.",
            hint: "Prune removes stopped containers, unused images, networks and build cache.", command: "docker system prune -a")
        add("dotdocker", "~/.docker", "~/.docker", .safe, .revealOnly, symbol: "shippingbox.fill",
            "Docker CLI config, contexts and buildx state.", hint: "Contains configuration; review before removing anything.")

        let vs = "~/Library/Application Support/Code"
        add("codeCache", "VS Code cache", vs + "/Cache", .safe, .trash, symbol: "chevron.left.forwardslash.chevron.right",
            "VS Code's web cache.", hint: "Rebuilt automatically; quit VS Code first.")
        add("codeCachedData", "VS Code CachedData", vs + "/CachedData", .safe, .trash, symbol: "chevron.left.forwardslash.chevron.right",
            "Compiled code caches, often for old VS Code versions.", hint: "Rebuilt automatically; quit VS Code first.")
        add("codeVSIX", "VS Code extension downloads", vs + "/CachedExtensionVSIXs", .safe, .trash, symbol: "chevron.left.forwardslash.chevron.right",
            "Downloaded extension packages.", hint: "Extensions stay installed; packages re-download on update.")
        add("slack", "Slack cache", "~/Library/Application Support/Slack/Cache", .safe, .trash, symbol: "bubble.left.and.bubble.right",
            "Slack's web cache.", hint: "Rebuilt automatically; quit Slack first.")
        add("spotify", "Spotify offline cache", "~/Library/Application Support/Spotify/PersistentCache", .safe, .trash, symbol: "music.note",
            "Cached and downloaded tracks.", hint: "Spotify re-streams tracks; offline downloads must be re-downloaded.")
        add("chrome", "Chrome cache", "~/Library/Caches/Google/Chrome", .safe, .trash, symbol: "globe",
            "Chrome's browser cache.", hint: "Rebuilt automatically; quit Chrome first.")
        add("mailDownloads", "Mail Downloads", "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .safe, .trash, symbol: "envelope",
            "Attachments you opened from Mail.", hint: "The originals stay in your mailbox.")
        add("iosBackups", "iOS device backups", "~/Library/Application Support/MobileSync/Backup", .safe, .revealOnly, symbol: "externaldrive",
            "Local iPhone/iPad backups.", hint: "Delete old backups in Finder > your device > Manage Backups.")

        // MARK: Claude Code
        for wt in claudeWorktreeDirs() {
            let repo = wt.deletingLastPathComponent().deletingLastPathComponent()
            list.append(Location(
                id: "wt:" + repo.path, title: "Claude worktrees in \(repo.lastPathComponent)", url: wt, category: .claude,
                summary: "Git worktrees Claude Code agents created in \(Location.tilde(repo.path)).",
                cleanHint: "Remove with git so the repo's worktree registry stays clean; branches survive removal unless you delete them explicitly.",
                actionKind: .command, command: nil, symbol: "point.3.connected.trianglepath.dotted", worktreeRepo: repo))
        }
        add("claudeJobs", "Claude Code jobs", "~/.claude/jobs", .claude, .trash, symbol: "sparkles",
            "Working data of background/remote Claude Code jobs.", hint: "Finished jobs don't need it; a running job would lose its working files.")
        add("claudeProjects", "Claude Code transcripts", "~/.claude/projects", .claude, .revealOnly, symbol: "text.bubble",
            "Conversation transcripts and project memory.", hint: "Deleting removes the ability to resume past sessions.")
        add("claudeHistory", "Claude Code file history", "~/.claude/file-history", .claude, .trash, symbol: "clock.arrow.circlepath",
            "Snapshots used to rewind file edits.", hint: "Old sessions can no longer be rewound.")
        add("claudeDebug", "Claude Code debug logs", "~/.claude/debug", .claude, .trash, symbol: "ladybug",
            "Debug logs.", hint: "Only needed for troubleshooting.")
        add("claudeDownloads", "Claude Code downloads", "~/.claude/downloads", .claude, .trash, symbol: "arrow.down.circle",
            "Downloaded updates and files.", hint: "Re-downloaded when needed.")
        add("claudeDesktop", "Claude desktop app data", "~/Library/Application Support/Claude", .claude, .revealOnly, symbol: "macwindow",
            "Claude desktop app data, including bundled runtimes and VMs.", hint: "Managed by the app; review in Finder.")
        add("claudeCliCache", "Claude CLI cache", "~/Library/Caches/claude-cli-nodejs", .claude, .trash, symbol: "archivebox",
            "Claude CLI cache and MCP logs.", hint: "Rebuilt automatically.")

        // MARK: Your content
        let ro = "Your own files — Spaceworthy never deletes these."
        add("downloads", "Downloads", "~/Downloads", .content, .revealOnly, symbol: "arrow.down.circle",
            "Files you downloaded.", hint: ro, trackOld: true)
        add("desktop", "Desktop", "~/Desktop", .content, .revealOnly, symbol: "menubar.dock.rectangle", "Files on your Desktop.", hint: ro)
        add("documents", "Documents", "~/Documents", .content, .revealOnly, symbol: "doc", "Your documents.", hint: ro)
        add("pictures", "Pictures", "~/Pictures", .content, .revealOnly, symbol: "photo", "Photos library and images.", hint: ro)
        add("movies", "Movies", "~/Movies", .content, .revealOnly, symbol: "film", "Videos and projects.", hint: ro)
        add("music", "Music", "~/Music", .content, .revealOnly, symbol: "music.note.list", "Music library.", hint: ro)
        add("icloud", "iCloud Drive (local)", "~/Library/Mobile Documents", .content, .revealOnly, symbol: "icloud",
            "Locally downloaded iCloud Drive files.", hint: "Use “Remove Download” in Finder to free space but keep files in iCloud.")
        add("messages", "Messages attachments", "~/Library/Messages/Attachments", .content, .revealOnly, symbol: "message",
            "Photos and files received in Messages.", hint: "Review in System Settings > General > Storage > Messages.")
        add("mail", "Mail", "~/Library/Mail", .content, .revealOnly, symbol: "envelope", "Local mailbox store.", hint: ro)
        add("userApps", "Applications (user)", "~/Applications", .content, .revealOnly, symbol: "square.grid.2x2", "Apps installed for your account.", hint: ro)
        add("apps", "Applications", "/Applications", .content, .revealOnly, symbol: "square.grid.2x2", "Installed apps.", hint: "Uninstall apps you no longer use.")
        add("projects", "Projects", "~/projects", .content, .revealOnly, symbol: "folder",
            "Your code projects.", hint: "node_modules folders regenerate with npm/pnpm/yarn install.", trackNodeModules: true)

        // MARK: System
        add("libUpdates", "Downloaded macOS updates", "/Library/Updates", .system, .systemInfo, symbol: "arrow.down.app",
            "Software updates downloaded but not yet installed.", hint: "Installing the update and restarting frees this space.")
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []).sorted()
        where name.hasPrefix("Install macOS") && name.hasSuffix(".app") {
            var loc = Location(id: "installer:" + name, title: name.replacingOccurrences(of: ".app", with: ""),
                               url: URL(fileURLWithPath: "/Applications/" + name), category: .system,
                               summary: "A full macOS installer.", cleanHint: "Delete the installer app if you don't plan to use it.",
                               actionKind: .systemInfo, symbol: "arrow.down.app")
            loc.isInstaller = true
            list.append(loc)
        }
        add("simRuntimeAsset", "Downloaded iOS Simulator runtime", "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime", .system, .command, symbol: "iphone.gen3",
            "Simulator runtime image downloaded by Xcode and kept by macOS.", hint: "SIP-protected: even sudo cannot delete it. Remove it with Xcode's simctl (install Xcode, run the command, then uninstall Xcode) or leave it; it is harmless but large.",
            command: "xcrun simctl runtime delete all")
        add("assetsV2", "macOS downloaded assets", "/System/Library/AssetsV2", .system, .systemInfo, symbol: "shippingbox",
            "Siri, dictation, fonts and other assets macOS downloads on demand.", hint: "Managed by macOS and SIP-protected; not user-removable.")
        add("sysCaches", "System caches", "/Library/Caches", .system, .systemInfo, symbol: "gearshape",
            "Caches shared by all users.", hint: "Managed by macOS.")
        add("sysLogs", "System logs", "/private/var/log", .system, .systemInfo, symbol: "list.bullet.rectangle",
            "System log files.", hint: "Rotated automatically by macOS.")
        add("diagnostics", "Unified log store", "/private/var/db/diagnostics", .system, .systemInfo, symbol: "stethoscope",
            "macOS unified logging database.", hint: "Trimmed automatically by macOS.")

        // Keep existing directories only; dedupe by path.
        var seen = Set<String>()
        return list.filter { loc in
            guard isDirectory(loc.url), !seen.contains(loc.url.path) else { return false }
            seen.insert(loc.url.path)
            return true
        }
    }
}
