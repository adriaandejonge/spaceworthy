import SwiftUI

struct CleanSheet: View {
    let request: CleanRequest
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.isEmptyTrash ? "Empty the Trash?" : "Move contents of \(request.title) to the Trash?",
                  systemImage: request.isEmptyTrash ? "trash" : "arrow.up.trash")
                .font(.headline)
            Text("\(request.itemCount) top-level item\(request.itemCount == 1 ? "" : "s"), about \(Fmt.bytes(request.bytes)).")
            Text(request.hint).foregroundStyle(.secondary)
            if request.isEmptyTrash {
                Text("This permanently deletes everything in the Trash. It cannot be undone.")
                    .foregroundStyle(.red)
            } else {
                Text("Items go to the Trash, so you can put them back. Quit the app that owns this folder first; items in use are skipped.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingClean = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.isEmptyTrash ? "Empty Trash" : "Move to Trash") { model.performClean(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
    }
}
