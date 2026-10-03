import SwiftUI

/// Shows what happened to an import batch.
///
/// ## Why this view exists
///
/// `AudioManager.importError` was written by every import failure and read by
/// nothing. A file that failed to import, a file that was silently skipped, and
/// a file the user never picked were all indistinguishable from the UI, so the
/// only visible signal that anything had gone wrong was the song count being
/// lower than expected. That is what made a double-`resume` process trap look
/// like a permissions bug.
///
/// Failures are grouped by cause, because "3 files could not be read" is
/// actionable and "3 files failed" is not.
struct ImportReportView: View {

    let report: ImportReport
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                summarySection

                if !report.succeeded.isEmpty {
                    Section("Added") {
                        ForEach(report.succeeded, id: \.id) { file in
                            Label(file.title, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                ForEach(Array(report.groupedFailures.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.names, id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(group.failure.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("\(group.failure.title) — \(group.names.count)")
                    } footer: {
                        if group.failure == .cloudNotDownloaded {
                            Text("Download the file in Files, then add it again.")
                        } else if group.failure == .noPermission {
                            Text("Re-add it from the Files app so Punches can be granted access.")
                        } else {
                            Text("Your original file has not been changed or moved.")
                        }
                    }
                }

                if report.succeeded.isEmpty && report.failed.isEmpty {
                    Section {
                        Text("Nothing was imported.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: headlineIcon)
                    .font(.title2)
                    .foregroundStyle(headlineStyle)

                Text(report.summary)
                    .font(.body)
            }
            .padding(.vertical, 4)
        }
    }

    private var headlineIcon: String {
        if report.failed.isEmpty { return "checkmark.circle.fill" }
        if report.succeeded.isEmpty { return "exclamationmark.triangle.fill" }
        return "exclamationmark.circle.fill"
    }

    private var headlineStyle: Color {
        if report.failed.isEmpty { return .green }
        if report.succeeded.isEmpty { return .red }
        return .orange
    }
}

#Preview {
    ImportReportView(
        report: ImportReport(
            succeeded: [
                AudioFile(fileName: "one.mp3", audioDuration: 120),
                AudioFile(fileName: "two.mp3", audioDuration: 180),
            ],
            failed: [
                FailedImport(
                    name: "cloud track.m4a",
                    failure: .cloudNotDownloaded,
                    underlying: "The file lives in iCloud Drive and had not finished downloading."
                ),
                FailedImport(name: "broken.wav", failure: .unsupportedCodec),
            ]
        ),
        onDismiss: {}
    )
}
