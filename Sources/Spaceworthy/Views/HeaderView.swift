import SwiftUI

struct HeaderView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").font(.title2)
                Text(model.disk?.name ?? "Macintosh HD").font(.title2.bold())
                if let d = model.disk {
                    Text("\(Fmt.bytes(d.total)) total").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                } else if let t = model.lastScan {
                    Text("Scanned \(t.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                }
            }

            if let d = model.disk {
                StackedBar(segments: [
                    (d.used, Color.blue),
                    (d.purgeable, Color.yellow),
                    (d.available, Color.secondary.opacity(0.25)),
                ])
                .frame(height: 18)

                HStack(spacing: 18) {
                    LegendItem(color: .blue, label: "Used", value: d.used)
                    LegendItem(color: .yellow, label: "Purgeable", value: d.purgeable)
                    LegendItem(color: .secondary.opacity(0.25), label: "Free", value: d.available)
                    Spacer()
                }
                .font(.callout)
            }

            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.green)
                Text("About \(Fmt.bytes(model.reclaimableBytes)) safely reclaimable")
                    .font(.title3.weight(.semibold))
                if model.isScanning { Text("(so far)").foregroundStyle(.secondary) }
            }

            if let d = model.disk, d.used > 0 {
                let share = Double(model.claudeTotal) / Double(d.used)
                if share > 0.10 {
                    Label("Claude Code accounts for \(Int((share * 100).rounded()))% of your used disk (\(Fmt.bytes(model.claudeTotal))).",
                          systemImage: "sparkles")
                        .foregroundStyle(.purple)
                }
            }

            if let msg = model.statusMessage {
                Text(msg).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StackedBar: View {
    let segments: [(Int64, Color)]

    var body: some View {
        GeometryReader { geo in
            let total = max(1, segments.reduce(0) { $0 + $1.0 })
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: geo.size.width * CGFloat(Double(seg.0) / Double(total)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: Int64

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
            Text(Fmt.bytes(value)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
