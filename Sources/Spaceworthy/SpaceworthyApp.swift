import AppKit
import SwiftUI

@main
struct SpaceworthyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Spaceworthy", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 900, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let path = ProcessInfo.processInfo.environment["SPACEWORTHY_SNAPSHOT"] {
            scheduleSnapshot(to: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Debug aid: once scanning finishes, render the main window to a PNG (no screen-recording permission needed).
    /// SPACEWORTHY_EXPAND=1 expands all rows (or a comma-separated list of row ids).
    /// Env: SPACEWORTHY_EXPAND=1|id,id (Overview rows), SPACEWORTHY_TAB=explore,
    /// SPACEWORTHY_EXPLORE_EXPAND=path,path (Explore folders to open, relative to ~ or absolute).
    private func scheduleSnapshot(to path: String) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let app = AppModel.shared
            try? await Task.sleep(for: .seconds(2))
            let giveUp = Date().addingTimeInterval(Double(env["SPACEWORTHY_SNAPSHOT_TIMEOUT"] ?? "") ?? 240)
            while (app.isScanning || app.worktreeStates.contains(where: \.gitLoading)) && Date() < giveUp {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let ids = env["SPACEWORTHY_EXPAND"] {
                let all = app.states.map(\.id)
                app.expandedRows = ids == "1" ? Set(all) : Set(ids.split(separator: ",").map(String.init))
            }
            let content: AnyView
            if env["SPACEWORTHY_TAB"] == "explore" {
                let ex = ExploreModel.shared
                app.tab = .explore
                ex.open(Locations.home)
                try? await Task.sleep(for: .seconds(1))
                while ex.isBusy && Date() < giveUp.addingTimeInterval(120) { try? await Task.sleep(for: .milliseconds(500)) }
                for rel in (env["SPACEWORTHY_EXPLORE_EXPAND"] ?? "").split(separator: ",") {
                    let target = rel.hasPrefix("/") ? String(rel) : Locations.home.path + "/" + rel
                    var stack = ex.root.map { [$0] } ?? []
                    while let n = stack.popLast() {
                        if n.url.path == target { if !n.expanded { ex.toggle(n) }; break }
                        stack.append(contentsOf: n.children ?? [])
                    }
                    try? await Task.sleep(for: .seconds(1))
                    while ex.isBusy && Date() < giveUp.addingTimeInterval(120) { try? await Task.sleep(for: .milliseconds(500)) }
                }
                content = AnyView(ExploreView(explore: ex, model: app))
            } else {
                content = AnyView(MainContent(model: app))
            }
            try? await Task.sleep(for: .seconds(1))
            let renderer = ImageRenderer(content: content
                .frame(width: 900)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if env["SPACEWORTHY_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }
}
