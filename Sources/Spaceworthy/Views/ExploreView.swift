import SwiftUI

/// Size-sorted drill-down of any folder, with a safety label per row. Only "Safe to clean" rows get a destructive action.
struct ExploreView: View {
    let explore: ExploreModel
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Explore").font(.title2.bold())
                Menu {
                    ForEach(ExploreRoot.allCases) { r in
                        Button(r.rawValue == "Home" ? "Home (~)" : r.rawValue) { explore.open(r.url) }
                    }
                    Divider()
                    Button("Choose Folder…") { explore.openPanel() }
                } label: {
                    Label(explore.root.map { Location.tilde($0.url.path) } ?? "Choose root", systemImage: "folder")
                }
                .fixedSize()
                if explore.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Sizing…").foregroundStyle(.secondary)
                }
                Spacer()
                if let r = explore.root {
                    Text("\(Fmt.bytes(r.effectiveBytes)) in \(r.children?.count ?? 0) items")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }

            SafetyLegend()

            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Safety").frame(width: 130, alignment: .leading)
                Text("Share").frame(width: 110, alignment: .leading)
                Text("Size").frame(width: 84, alignment: .trailing)
                Text("Files").frame(width: 70, alignment: .trailing)
                Text("Modified").frame(width: 110, alignment: .leading)
                Color.clear.frame(width: 110)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(explore.visibleRows(), id: \.0.id) { node, depth in
                    ExploreRow(node: node, depth: depth, parentBytes: node.parent?.effectiveBytes ?? 0, explore: explore, model: model)
                    Divider()
                }
            }
            if explore.root?.isLoadingChildren == true {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(20)
    }
}

struct SafetyLegend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: 6) {
            ForEach(SafetyLabel.allCases) { l in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: l.symbol).foregroundStyle(l.color).frame(width: 16)
                    (Text(l.title).bold() + Text(" — " + l.explanation).foregroundColor(.secondary))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ExploreRow: View {
    let node: ExploreNode
    let depth: Int
    let parentBytes: Int64
    let explore: ExploreModel
    let model: AppModel

    var body: some View {
        let label = explore.label(for: node.url, app: model)
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
                Button { explore.toggle(node) } label: {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(node.isDirectory ? 1 : 0)
                .disabled(!node.isDirectory)
                Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(node.isDirectory ? Color.accentColor.opacity(0.8) : Color.secondary)
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if node.isLoadingChildren { ProgressView().controlSize(.mini) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(node.url.path)

            HStack(spacing: 4) {
                Image(systemName: label.symbol).foregroundStyle(label.color)
                Text(label.title).foregroundStyle(label.color).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .frame(width: 130, alignment: .leading)
            .help(label.explanation)

            ProportionBar(fraction: parentBytes > 0 ? Double(node.bytes ?? 0) / Double(parentBytes) : 0, color: label.color)
                .frame(width: 110, height: 7)

            Group {
                if node.noAccess {
                    Text("no access").foregroundStyle(.secondary)
                } else if node.bytes == nil {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 3) {
                        if node.isSizing { ProgressView().controlSize(.mini) }
                        Text((node.partial ? "≥ " : "") + Fmt.bytes(node.bytes ?? 0)).monospacedDigit()
                            .fontWeight((node.bytes ?? 0) > 1_000_000_000 ? .semibold : .regular)
                    }
                }
            }
            .frame(width: 84, alignment: .trailing)

            Text(node.itemCount.map { $0.formatted() } ?? "")
                .foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 70, alignment: .trailing)

            Text(RelTime.string(node.modified)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 110, alignment: .leading)
                .help(RelTime.tooltip("Modified", node.modified))

            actions(label).frame(width: 110, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .opacity(node.isHidden ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { explore.toggle(node) }
    }

    @ViewBuilder private func actions(_ label: SafetyLabel) -> some View {
        HStack(spacing: 6) {
            if label == .safe {
                if ExploreModel.isWorktree(node.url) {
                    Button("Remove…") { model.requestRemoval(worktreePath: node.url.path) }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .help("Remove this git worktree (with git, after a confirmation)")
                } else if node.url.path.hasSuffix("/.claude/worktrees") {
                    Button("Review…") { model.requestRemoval(worktreePath: node.url.path + "/") }
                } else {
                    Button("Clean…") { model.requestExploreClean(node) }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .disabled(node.isSizing || node.bytes == nil || node.bytes == 0)
                }
            }
            Button { model.reveal(node.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .controlSize(.small)
    }
}
