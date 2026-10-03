import SwiftUI
import Combine

struct SpectrumView: View {
    @ObservedObject var analyzer: UnifiedAudioAnalyser
    @EnvironmentObject var theme: ThemeManager
    @State private var time: Double = 0
    let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    // Minimeters Style Gradient: Cold (Bottom) to Hot (Top)
    private let minimetersGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color(red: 255/255, green: 50/255, blue: 50/255),   // Red (Clipping)
            Color(red: 255/255, green: 200/255, blue: 50/255),  // Yellow (Loud)
            Color(red: 50/255, green: 200/255, blue: 100/255),  // Green (Good)
            Color(red: 50/255, green: 100/255, blue: 255/255)   // Blue (Quiet)
        ]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        VStack {
            ZStack {

                // Custom Spectrum Visualization
                GeometryReader { geometry in
                    Canvas { context, size in
                        let bandWidth = size.width / CGFloat(analyzer.spectrumBands.count)
                        
                        for (index, magnitude) in analyzer.spectrumBands.enumerated() {
                            let x = CGFloat(index) * bandWidth
                            let barHeight = CGFloat(magnitude) * size.height
                            let y = size.height - barHeight
                            
                            // Draw the bar
                            let rect = CGRect(x: x, y: y, width: bandWidth - 1, height: barHeight)
                            
                            // Calculate color based on height (minimeters style)
                            let heightPercent = magnitude
                            let color: Color
                            if heightPercent > 0.85 {
                                color = Color(red: 255/255, green: 50/255, blue: 50/255) // Red
                            } else if heightPercent > 0.6 {
                                color = Color(red: 255/255, green: 200/255, blue: 50/255) // Yellow
                            } else if heightPercent > 0.3 {
                                color = Color(red: 50/255, green: 200/255, blue: 100/255) // Green
                            } else {
                                color = Color(red: 50/255, green: 100/255, blue: 255/255) // Blue
                            }
                            
                            context.fill(Path(rect), with: .color(color.opacity(0.8)))
                            
                            // Draw peak hold
                            if analyzer.peakHolds.indices.contains(index) {
                                let peak = analyzer.peakHolds[index]
                                let peakY = size.height - (CGFloat(peak) * size.height)
                                let peakRect = CGRect(x: x, y: peakY - 1, width: bandWidth - 1, height: 2)
                                context.fill(Path(peakRect), with: .color(.white.opacity(0.9)))
                            }
                        }
                    }
                }
                
                // Overlay the Grid (Hz/kHz)
                FrequencyGridOverlay()
            }
            // Container Styling
            .frame(height: 160)
            .cornerRadius(8)
            // The "Minimeters" white border
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .onReceive(timer) { _ in time += 1.0 / 60.0 }
    }
}

// Your original grid logic, optimized for SwiftUI
struct FrequencyGridOverlay: View {
    /// Swift has no key-path support for tuple elements, so the grid lines are
    /// a proper `Identifiable` type rather than `[(String, Float)]`.
    struct GridLine: Identifiable {
        let label: String
        let hz: Float
        var id: Float { hz }
    }

    let freqs: [GridLine] = [
        GridLine(label: "100", hz: 100),
        GridLine(label: "1k", hz: 1000),
        GridLine(label: "5k", hz: 5000),
        GridLine(label: "10k", hz: 10000),
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(freqs) { line in
                // Calculate position (Logarithmic)
                let xPercent = log10(line.hz / 20.0) / log10(20000.0 / 20.0)
                let xPos = CGFloat(xPercent) * geo.size.width

                // Draw Line
                Path { path in
                    path.move(to: CGPoint(x: xPos, y: 0))
                    path.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                }
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

                // Draw Label
                Text(line.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .position(x: xPos + 10, y: geo.size.height - 10)
            }
        }
        .allowsHitTesting(false) // Pass touches through to controls below
    }
}
