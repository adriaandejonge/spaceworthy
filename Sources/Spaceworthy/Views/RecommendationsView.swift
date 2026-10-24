import SwiftUI

struct RecommendationsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended next actions").font(.title3.bold())
            let recs = model.recommendations
            if recs.isEmpty {
                Text(model.isScanning ? "Scanning… recommendations appear as sizes come in." : "Nothing to recommend.")
                    .foregroundStyle(.secondary)
            }
            ForEach(recs) { rec in
                RecommendationCard(rec: rec, model: model)
            }
        }
    }
}

struct RecommendationCard: View {
    let rec: Recommendation
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(rec.severity.color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title).font(.headline)
                Text(rec.rationale).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let b = rec.bytes {
                Text(Fmt.bytes(b)).font(.headline).monospacedDigit()
            }
            actionButton.frame(minWidth: 120, alignment: .trailing)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var actionButton: some View {
        switch rec.action {
        case .clean(let id):
            Button(model.state(id)?.location.actionKind == .emptyTrash ? "Empty Trash…" : "Clean…") {
                model.requestClean(id)
            }
            .buttonStyle(.borderedProminent)
        case .reveal(let url):
            Button("Reveal") { model.reveal(url) }
        case .copy(let cmd):
            Button("Copy command") { model.copy(cmd) }.help(cmd)
        case .openURL(let url, let label):
            Button(label) { model.open(url) }
        case .show(let id, let label):
            Button(label) { model.show(id) }
                .buttonStyle(.borderedProminent).tint(.purple)
        case .none:
            EmptyView()
        }
    }
}
