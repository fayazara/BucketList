import SwiftUI

struct TransfersButton: View {
    let app: AppModel
    @State private var isShowing = false

    var body: some View {
        let center = app.transfers
        Button {
            isShowing.toggle()
        } label: {
            Label("Transfers", systemImage: center.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
        }
        .help(center.activeCount > 0 ? "\(center.activeCount) transfers in progress" : "Transfers")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            TransfersList(center: center)
        }
        .onChange(of: center.transfers.first?.id) { _, newValue in
            if newValue != nil { isShowing = true }
        }
    }
}

private struct TransfersList: View {
    let center: TransferCenter

    var body: some View {
        VStack(spacing: 0) {
            if center.transfers.isEmpty {
                Text("No transfers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(center.transfers) { transfer in
                    TransferRow(transfer: transfer)
                }
                .listStyle(.plain)
                .frame(minHeight: 120, maxHeight: 360)
                Divider()
                HStack {
                    Spacer()
                    Button("Clear Finished") { center.clearFinished() }
                        .disabled(center.transfers.allSatisfy { $0.state == .running })
                }
                .padding(8)
            }
        }
        .frame(width: 340)
    }
}

private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch transfer.state {
                case .running:
                    ProgressView(value: transfer.fraction)
                        .controlSize(.small)
                case .done:
                    Text(transfer.direction == .upload ? "Uploaded" : "Downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            if let url = transfer.localURL {
                Spacer(minLength: 0)
                Button("Show in Finder", systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
