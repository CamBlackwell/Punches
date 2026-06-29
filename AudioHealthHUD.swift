import SwiftUI

#if DEBUG
struct AudioHealthHUD: View {
    @ObservedObject var manager: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Engine Starves: \(manager.currentEngine?.debugMetrics.starveCount ?? 0)")
            Text("Max Scheduled Ahead: \(manager.currentEngine?.debugMetrics.maxScheduledAhead ?? 0)")
            Text(String(format: "Avg Schedule: %.2f ms", manager.currentEngine?.debugMetrics.avgScheduleMs ?? 0))
            Text(String(format: "Tap Max: %.0f µs", manager.audioAnalyzer.tapCallbackMaxUs))
            Text("Tap Overruns: \(manager.audioAnalyzer.tapOverrunCount)")
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(8)
        .background(Color.black.opacity(0.65))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .padding(8)
    }
}
#endif
