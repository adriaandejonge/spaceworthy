import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    let explore = ExploreModel.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch model.tab {
                case .overview:
                    MainContent(model: model)
                case .explore:
                    ExploreView(explore: explore, model: model)
                }
            }
            .onChange(of: model.scrollRequest) { _, target in
                guard let target else { return }
                model.tab = .overview
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    model.scrollRequest = nil
                }
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if model.tab == .explore, let r = explore.root { explore.open(r.url) }
                    else { Task { await model.refresh() } }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.tab == .overview && model.isScanning)
                .help("Rescan")

                Button {
                    model.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                } label: {
                    Label("Open Storage Settings", systemImage: "internaldrive")
                }
                .help("Open System Settings > General > Storage")
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.tab) { _, tab in
            if tab == .explore, explore.root == nil { explore.open(Locations.home) }
        }
        .sheet(item: $model.pendingClean) { req in
            CleanSheet(request: req, model: model)
        }
        .background {
            Color.clear.sheet(item: $model.pendingRemoval) { req in
                WorktreeRemovalSheet(request: req, model: model)
            }
        }
        .alert("Worktree removal", isPresented: Binding(get: { model.resultMessage != nil },
                                                        set: { if !$0 { model.resultMessage = nil } })) {
            Button("OK") { model.resultMessage = nil }
        } message: {
            Text(model.resultMessage ?? "")
        }
    }
}

/// The Overview page content (also used by the snapshot debug hook).
struct MainContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeaderView(model: model)
            RecommendationsView(model: model)
            ForEach(LocationCategory.allCases) { cat in
                if !model.states(in: cat).isEmpty || cat == .system {
                    LocationSection(category: cat, model: model).id("section-" + cat.id)
                }
            }
            Text("Clean moves items to the Trash; nothing is deleted permanently until you empty it. Worktrees are removed with git.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(20)
    }
}
