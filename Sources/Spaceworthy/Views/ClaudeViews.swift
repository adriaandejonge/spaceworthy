import SwiftUI

enum RelTime {
    static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func string(_ d: Date?) -> String {
        guard let d else { return "?" }
        return formatter.localizedString(for: d, relativeTo: Date())
    }

    static func tooltip(_ label: String, _ d: Date?) -> String {
        "\(label): " + (d.map { absolute.string(from: $0) } ?? "unknown")
    }
}

/// "N worktrees across M projects, X GB — Y GB safe to remove, Z GB older than 30 days."
struct ClaudeSummary: View {
    let model: AppModel

    var body: some View {
        let groups = model.worktreeStates
        let all = model.allWorktrees
        if !all.isEmpty {
            let total = groups.reduce(0) { $0 + $1.bytes }
            let safe = all.filter { $0.verdict == .safe }.reduce(0) { $0 + $1.bytes }
            let old = all.filter { $0.ageDays > 30 }.reduce(0) { $0 + $1.bytes }
            let loading = groups.contains { $0.gitLoading }
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple)
                Text("\(all.count) worktrees across \(groups.count) project\(groups.count == 1 ? "" : "s"), \(Fmt.bytes(total))")
                    .fontWeight(.medium)
                Text(loading ? "— checking git status…" :
                        "— \(Fmt.bytes(safe)) in worktrees safe to remove, \(Fmt.bytes(old)) older than 30 days.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

struct WorktreeGroupView: View {
    let state: LocationState
    let model: AppModel

    var body: some View {
        DisclosureGroup(isExpanded: model.groupBinding(state)) {
            content.padding(.leading, 4).padding(.vertical, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(state.repoName) — \(state.worktrees.count) worktree\(state.worktrees.count == 1 ? "" : "s"), \(Fmt.bytes(state.bytes))")
                        .fontWeight(.medium)
                    Text(Location.tilde(state.location.worktreeRepo?.path ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if state.gitLoading {
                    ProgressView().controlSize(.small)
                    Text("checking git…").font(.caption).foregroundStyle(.secondary)
                }
                SizeLabel(state: state).frame(width: 92, alignment: .trailing)
            }
            .padding(.vertical, 6)
        }
        .padding(.leading, 6)
    }

    @ViewBuilder private var content: some View {
        let visible = model.visibleWorktrees(state)
        let selected = model.selected(in: state)
        let selBytes = selected.reduce(0) { $0 + $1.bytes }
        let filter = model.worktreeFilter[state.id] ?? .all
        let allShownSelected = !visible.isEmpty && visible.allSatisfy { model.selectedWorktrees.contains($0.id) }

        VStack(alignment: .leading, spacing: 8) {
            Text(state.location.cleanHint).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(WorktreeFilter.allCases) { f in
                    let count = state.worktrees.filter(f.matches).count
                    Button { model.worktreeFilter[state.id] = f } label: {
                        Text("\(f.rawValue) (\(count))")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(f == filter ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(f == filter ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Toggle("Select all shown", isOn: Binding(
                    get: { allShownSelected },
                    set: { on in
                        for w in visible {
                            if on { model.selectedWorktrees.insert(w.id) } else { model.selectedWorktrees.remove(w.id) }
                        }
                    }))
                    .toggleStyle(.checkbox)
                    .disabled(visible.isEmpty)
                Button {
                    model.requestRemoval(state)
                } label: {
                    Text("Remove selected (\(selected.count), \(Fmt.bytes(selBytes)))").bold()
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(selected.isEmpty || state.gitLoading)
            }

            // Header
            HStack(spacing: 8) {
                Color.clear.frame(width: 18)
                SortHeader(title: "Name", key: .name, state: state, model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Branch").frame(width: 150, alignment: .leading)
                Text("Verdict").frame(width: 270, alignment: .leading)
                SortHeader(title: "Last activity", key: .age, state: state, model: model)
                    .frame(width: 110, alignment: .leading)
                SortHeader(title: "Size", key: .size, state: state, model: model)
                    .frame(width: 80, alignment: .trailing)
                Color.clear.frame(width: 22)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if visible.isEmpty {
                Text("No worktrees match this filter.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(visible) { wt in
                WorktreeGridRow(wt: wt, model: model)
            }
        }
    }
}

struct SortHeader: View {
    let title: String
    let key: WorktreeSort
    let state: LocationState
    let model: AppModel

    var body: some View {
        let (cur, asc) = model.worktreeSort[state.id] ?? (.size, false)
        Button { model.setSort(key, for: state) } label: {
            HStack(spacing: 2) {
                Text(title)
                if cur == key { Image(systemName: asc ? "chevron.up" : "chevron.down").font(.caption2) }
            }
        }
        .buttonStyle(.plain)
    }
}

struct WorktreeGridRow: View {
    let wt: WorktreeInfo
    let model: AppModel

    var body: some View {
        let v = wt.verdict
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.selectedWorktrees.contains(wt.id) },
                                     set: { _ in model.toggle(wt.id, in: \.selectedWorktrees) }))
                .toggleStyle(.checkbox).labelsHidden().frame(width: 18)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(wt.gitLoaded ? v.color : .gray).frame(width: 3, height: 16)
                Text(wt.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(wt.url.path)
            Text(wt.branch ?? "?").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            HStack(spacing: 4) {
                if wt.gitLoaded {
                    Badge(text: v.title, color: v.color)
                    if wt.dirty == true { Badge(text: "uncommitted changes", color: .red) }
                    else if wt.merged == true { Badge(text: "merged into \(wt.defaultBranch ?? "main")", color: .green) }
                    else if wt.hasUpstream == false, !wt.detached { Badge(text: "no upstream", color: .orange) }
                    else if (wt.unpushed ?? 0) > 0 { Badge(text: "unpushed", color: .orange) }
                } else {
                    Text("checking…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 270, alignment: .leading)
            .clipped()
            Text(RelTime.string(wt.lastCommit ?? wt.modified)).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
                .help(RelTime.tooltip("Last commit", wt.lastCommit) + "\n" + RelTime.tooltip("Folder modified", wt.modified))
            Text(Fmt.bytes(wt.bytes)).font(.callout).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { model.reveal(wt.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).frame(width: 22).help("Reveal in Finder")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(wt.gitLoaded ? v.color.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color == .yellow ? Color.orange : color)
    }
}

struct WorktreeRemovalSheet: View {
    @Bindable var request: WorktreeRemovalRequest
    let model: AppModel

    var body: some View {
        let groups: [(WorktreeVerdict, [WorktreeInfo])] = [WorktreeVerdict.safe, .probablySafe, .unsaved].compactMap { (v: WorktreeVerdict) -> (WorktreeVerdict, [WorktreeInfo])? in
            let l = request.items.filter { $0.verdict == v }
            return l.isEmpty ? nil : (v, l)
        }
        VStack(alignment: .leading, spacing: 12) {
            Label("Remove \(request.items.count) worktree\(request.items.count == 1 ? "" : "s") from \(request.repo.lastPathComponent)?",
                  systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Each is removed with `git worktree remove --force`, then `git worktree prune` runs once. Files are deleted by git, not moved to the Trash.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.0) { verdict, list in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(verdict.title) (\(list.count), \(Fmt.bytes(list.reduce(0) { $0 + $1.bytes })))")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(verdict == .unsaved ? Color.red : verdict == .safe ? Color.green : Color.orange)
                            ForEach(list) { w in
                                HStack {
                                    Text(w.name).lineLimit(1)
                                    Text(w.branch ?? "?").foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.bytes(w.bytes)).monospacedDigit()
                                }
                                .font(.callout)
                                .foregroundStyle(verdict == .unsaved && !request.includeUnsaved ? Color.red.opacity(0.6) : verdict == .unsaved ? Color.red : Color.primary)
                                .strikethrough(verdict == .unsaved && !request.includeUnsaved)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            if !request.unsaved.isEmpty {
                Toggle("Also remove \(request.unsaved.count) worktree\(request.unsaved.count == 1 ? "" : "s") with unsaved work (uncommitted or unpushed changes are lost)",
                       isOn: $request.includeUnsaved)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.red)
            }
            Toggle("Also delete the worktree's branch (never the default branch or a detached HEAD)", isOn: $request.deleteBranches)
                .toggleStyle(.checkbox)

            HStack {
                Text("Will remove \(request.effective.count), about \(Fmt.bytes(request.effectiveBytes)).")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(request.effective.count)") { model.performRemoval(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(request.effective.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Fine-grained list of ~/.claude/jobs folders, selectable for "Trash selected".
struct JobsListView: View {
    let state: LocationState
    let model: AppModel

    var body: some View {
        let items = state.items
        let selected = items.filter { model.selectedJobs.contains($0.id) }
        let maxBytes = items.first?.bytes ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Select all", isOn: Binding(
                    get: { !items.isEmpty && selected.count == items.count },
                    set: { on in model.selectedJobs = on ? Set(items.map(\.id)) : [] }))
                    .toggleStyle(.checkbox)
                Button("Select older than 7 days") {
                    let cutoff = Date().addingTimeInterval(-7 * 86_400)
                    model.selectedJobs = Set(items.filter { ($0.modified ?? .distantFuture) < cutoff }.map(\.id))
                }
                .controlSize(.small)
                Spacer()
                Button {
                    model.requestTrashSelectedJobs()
                } label: {
                    Text("Trash selected (\(selected.count), \(Fmt.bytes(selected.reduce(0) { $0 + $1.bytes })))").bold()
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(selected.isEmpty)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { model.selectedJobs.contains(item.id) },
                                             set: { _ in model.toggle(item.id, in: \.selectedJobs) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(RelTime.string(item.modified)).font(.callout).foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                        .help(RelTime.tooltip("Modified", item.modified))
                    ProportionBar(fraction: maxBytes > 0 ? Double(item.bytes) / Double(maxBytes) : 0, color: .purple.opacity(0.6))
                        .frame(width: 100, height: 6)
                    Text(Fmt.bytes(item.bytes)).font(.callout).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Button { model.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Reveal in Finder")
                }
                .padding(.trailing, 4)
            }
        }
    }
}
