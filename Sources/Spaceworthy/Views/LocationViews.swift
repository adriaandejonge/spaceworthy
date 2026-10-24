import SwiftUI

struct LocationSection: View {
    let category: LocationCategory
    let model: AppModel

    var body: some View {
        let states = model.sortedStates(in: category)
        let rows = states.filter { $0.location.worktreeRepo == nil }
        let groups = states.filter { $0.location.worktreeRepo != nil }
        let maxBytes = rows.map(\.bytes).max() ?? 0
        let total = states.reduce(0) { $0 + $1.bytes }

        DisclosureGroup(isExpanded: model.sectionBinding(category.id)) {
            VStack(alignment: .leading, spacing: 0) {
                if category == .claude {
                    ClaudeSummary(model: model).padding(.vertical, 6)
                    ForEach(groups) { g in
                        WorktreeGroupView(state: g, model: model).id(g.id)
                        Divider()
                    }
                }
                ForEach(rows) { s in
                    LocationRow(state: s, maxBytes: maxBytes, model: model).id(s.id)
                    Divider()
                }
                if category == .system {
                    SystemInfoView(model: model)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: category.symbol).foregroundStyle(category.color)
                Text(category.title).font(.title3.bold())
                Text(Fmt.bytes(total)).foregroundStyle(.secondary).monospacedDigit()
                Text(category.subtitle).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

struct LocationRow: View {
    let state: LocationState
    let maxBytes: Int64
    let model: AppModel

    private var loc: Location { state.location }
    private var expanded: Bool { model.expandedRows.contains(state.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { model.toggleRow(state.id) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: loc.symbol)
                    .foregroundStyle(loc.category.color)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.title).fontWeight(.medium).lineLimit(1)
                    Text(loc.displayPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

                ProportionBar(fraction: maxBytes > 0 ? Double(state.bytes) / Double(maxBytes) : 0,
                              color: loc.category.color)
                    .frame(width: 130, height: 8)

                SizeLabel(state: state)
                    .frame(width: 92, alignment: .trailing)

                buttons.frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.reveal(loc.url) }
            .help(loc.summary)

            if let extra = extraLine {
                Text(extra).font(.caption).foregroundStyle(.secondary).padding(.leading, 56).padding(.bottom, 4)
            }

            if expanded { detail.padding(.leading, 56).padding(.bottom, 8) }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            switch loc.actionKind {
            case .trash:
                Button { model.requestClean(state.id) } label: { Text("Clean").bold() }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(state.isScanning || state.bytes == 0)
            case .emptyTrash:
                Button { model.requestClean(state.id) } label: { Text("Empty Trash").bold() }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(state.isScanning || state.bytes == 0)
            case .command:
                if let cmd = loc.command {
                    Button("Copy") { model.copy(cmd) }.help(cmd)
                }
            default:
                EmptyView()
            }
            Button { model.reveal(loc.url) } label: { Image(systemName: "magnifyingglass") }
                .help("Reveal in Finder")
        }
        .controlSize(.small)
    }

    private var extraLine: String? {
        if loc.trackOld, state.hasScanned, state.oldBytes > 0 {
            return "\(Fmt.bytes(state.oldBytes)) in files older than 30 days"
        }
        if loc.trackNodeModules, state.nodeModulesBytes > 0 {
            return "node_modules: \(Fmt.bytes(state.nodeModulesBytes)) (regenerates with install)"
        }
        if loc.id == "claudeJobs", state.hasScanned, !state.items.isEmpty {
            return "\(state.items.count) job folders, \(Fmt.bytes(model.oldJobBytes)) untouched for over a week"
        }
        return nil
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.summary).font(.callout)
            Text(loc.cleanHint).font(.callout).foregroundStyle(.secondary)
            if let cmd = loc.command {
                CommandLine(command: cmd, model: model)
            }
            if state.hasScanned {
                Text(scanInfo).font(.caption).foregroundStyle(.tertiary)
            }
            if loc.id == "claudeJobs" {
                JobsListView(state: state, model: model)
            } else if !state.children.isEmpty {
                let maxChild = state.children.first?.bytes ?? 0
                ForEach(state.children) { c in
                    HStack(spacing: 8) {
                        Text(c.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ProportionBar(fraction: maxChild > 0 ? Double(c.bytes) / Double(maxChild) : 0,
                                      color: loc.category.color.opacity(0.6))
                            .frame(width: 100, height: 6)
                        Text(Fmt.bytes(c.bytes)).font(.callout).monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                        Button { model.reveal(c.url) } label: { Image(systemName: "magnifyingglass") }
                            .controlSize(.mini).buttonStyle(.borderless).help("Reveal in Finder")
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private var scanInfo: String {
        var s = "Scanned \(state.fileCount.formatted()) files in \(String(format: "%.1f", state.duration)) s"
        if state.partial { s += " — stopped at the time limit, size is a lower bound" }
        if state.unreadable > 0 { s += " — \(state.unreadable.formatted()) items unreadable" }
        return s
    }
}

struct SizeLabel: View {
    let state: LocationState

    var body: some View {
        if state.noAccess {
            Text("no access").foregroundStyle(.secondary).help("Grant Full Disk Access to Spaceworthy to size this folder.")
        } else if state.isScanning && state.bytes == 0 {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 4) {
                if state.isScanning { ProgressView().controlSize(.mini) }
                Text((state.partial ? "≥ " : "") + Fmt.bytes(state.bytes))
                    .monospacedDigit()
                    .fontWeight(state.bytes > 1_000_000_000 ? .semibold : .regular)
            }
        }
    }
}

struct CommandLine: View {
    let command: String
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Button("Copy") { model.copy(command) }.controlSize(.mini)
        }
    }
}

struct ProportionBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
    }
}

struct SystemInfoView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.orange).frame(width: 22)
                    .padding(.leading, 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Time Machine local snapshots").fontWeight(.medium)
                    if !model.snapshotsLoaded {
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    } else if model.snapshots.isEmpty {
                        Text("None").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(model.snapshots.count) snapshot\(model.snapshots.count == 1 ? "" : "s"): "
                             + model.snapshots.suffix(6).joined(separator: ", ")
                             + (model.snapshots.count > 6 ? ", …" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("They count as purgeable; macOS deletes them when space is needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        CommandLine(command: "tmutil thinlocalsnapshots / 50000000000 4", model: model)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)

            if let sw = model.softwareUpdateText {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.app").foregroundStyle(.orange).frame(width: 22).padding(.leading, 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("softwareupdate --list --no-scan").fontWeight(.medium)
                        Text(sw).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Open Software Update") { model.open(Recommendations.softwareUpdateURL) }
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
    }
}
