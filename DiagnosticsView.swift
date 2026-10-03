import SwiftUI

/// A minimal, self-contained debug screen for viewing and sharing the
/// diagnostics log. Wire it up temporarily (e.g. a button in Settings, or a
/// long-press somewhere) — it's not meant to ship to end users.
struct DiagnosticsView: View {
    @EnvironmentObject var audioManager: AudioManager
    @State private var logText: String = ""
    @State private var showShareSheet = false
    @State private var showClearConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Refresh") { refresh() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button("Clear") { showClearConfirm = true }
                        Button("Share") { showShareSheet = true }
                    }
                }
            }
            .onAppear { refresh() }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(
                    activityItems: [
                        audioManager.diagnosticsService.logFileURLForSharing()
                    ]
                )
            }
            .confirmationDialog("Clear diagnostics log?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) {
                    audioManager.diagnosticsService.clearLog()
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func refresh() {
        logText = audioManager.diagnosticsService.readFullLog()
    }
}
