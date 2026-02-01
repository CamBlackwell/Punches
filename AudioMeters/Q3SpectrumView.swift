import SwiftUI

struct Q3AnalyzerView: View {
    @ObservedObject var analyzer: UnifiedAudioAnalyser
    @EnvironmentObject var theme: ThemeManager
    
    @State private var referenceLevel: Float = -12.0
    @State private var smoothedBands: [Float] = []
    
    private let minDB: Float = -60
    private let maxDB: Float = 6
    private let smoothingFactor: Float = 0.3
    
    private let dbLines: [Float] = [-60, -48, -36, -24, -12, 0, 6]
    
    private let freqMarkers: [(freq: Float, label: String)] = [
        (20, "20"),
        (50, "50"),
        (100, "100"),
        (200, "200"),
        (500, "500"),
        (1000, "1k"),
        (2000, "2k"),
        (5000, "5k"),
        (10000, "10k"),
        (20000, "20k")
    ]
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black
                
                Canvas { context, size in
                    drawDBGrid(context: context, size: size)
                    drawFrequencyLabels(context: context, size: size)
                    drawPeakHold(context: context, size: size)
                    drawSpectrumCurve(context: context, size: size)
                }
                .onChange(of: analyzer.spectrumBands) { oldValue, newValue in
                    updateSmoothedBands(newValue)
                }
                
                VStack(spacing: 4) {
                    Button(action: { referenceLevel -= 3 }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Text("\(Int(referenceLevel))dB")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Button(action: { referenceLevel += 3 }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(8)
            }
        }
        .onAppear {
            smoothedBands = Array(repeating: 0, count: analyzer.spectrumBands.count)
        }
    }
    
    private func updateSmoothedBands(_ newBands: [Float]) {
        if smoothedBands.count != newBands.count {
            smoothedBands = newBands
            return
        }
        
        for i in 0..<newBands.count {
            smoothedBands[i] = smoothedBands[i] * (1 - smoothingFactor) + newBands[i] * smoothingFactor
        }
    }
    
    private func drawDBGrid(context: GraphicsContext, size: CGSize) {
        let usableHeight = size.height - 30
        
        for db in dbLines {
            let y = dbToY(db, height: usableHeight)
            
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width - 60, y: y))
            
            let opacity: Double
            let lineWidth: CGFloat
            
            if db == 0 {
                opacity = 0.6
                lineWidth = 1.5
            } else if db > 0 {
                opacity = 0.4
                lineWidth = 1.0
            } else {
                opacity = 0.15
                lineWidth = 0.5
            }
            
            context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: lineWidth)
            
            let dbText = Text("\(Int(db))")
                .font(.system(size: 9, weight: db == 0 ? .semibold : .light))
                .foregroundColor(.white.opacity(db == 0 ? 0.8 : 0.5))
            
            context.draw(dbText, at: CGPoint(x: size.width - 40, y: y - 4))
        }
    }
    
    private func drawFrequencyLabels(context: GraphicsContext, size: CGSize) {
        let usableHeight = size.height - 30
        
        for marker in freqMarkers {
            let x = frequencyToX(marker.freq, width: size.width - 60)
            
            var tickPath = Path()
            tickPath.move(to: CGPoint(x: x, y: usableHeight))
            tickPath.addLine(to: CGPoint(x: x, y: usableHeight + 4))
            context.stroke(tickPath, with: .color(.white.opacity(0.3)), lineWidth: 1)
            
            let freqText = Text(marker.label)
                .font(.system(size: 8, weight: .light))
                .foregroundColor(.white.opacity(0.6))
            
            context.draw(freqText, at: CGPoint(x: x, y: usableHeight + 12))
        }
    }
    
    private func drawSpectrumCurve(context: GraphicsContext, size: CGSize) {
        let usableHeight = size.height - 30
        let usableWidth = size.width - 60
        let bands = smoothedBands.isEmpty ? analyzer.spectrumBands : smoothedBands
        guard bands.count > 1 else { return }
        
        var curvePath = Path()
        var fillPath = Path()
        
        var points: [(x: CGFloat, y: CGFloat, db: Float)] = []
        
        for i in 0..<bands.count {
            let x = (CGFloat(i) / CGFloat(bands.count - 1)) * usableWidth
            let db = magnitudeToCalibratedDB(bands[i])
            let y = dbToY(db, height: usableHeight)
            
            points.append((x, y, db))
        }
        
        guard points.count > 2 else { return }
        
        fillPath.move(to: CGPoint(x: 0, y: usableHeight))
        fillPath.addLine(to: CGPoint(x: points[0].x, y: points[0].y))
        curvePath.move(to: CGPoint(x: points[0].x, y: points[0].y))
        
        for i in 1..<points.count {
            let current = points[i]
            let previous = points[i - 1]
            
            if i == 1 {
                curvePath.addLine(to: CGPoint(x: current.x, y: current.y))
                fillPath.addLine(to: CGPoint(x: current.x, y: current.y))
            } else {
                let previous2 = points[i - 2]
                
                let cp1x = previous.x + (current.x - previous2.x) / 6
                let cp1y = previous.y + (current.y - previous2.y) / 6
                
                let cp2x = current.x - (current.x - previous.x) / 3
                let cp2y = current.y - (current.y - previous.y) / 3
                
                curvePath.addCurve(
                    to: CGPoint(x: current.x, y: current.y),
                    control1: CGPoint(x: cp1x, y: cp1y),
                    control2: CGPoint(x: cp2x, y: cp2y)
                )
                
                fillPath.addCurve(
                    to: CGPoint(x: current.x, y: current.y),
                    control1: CGPoint(x: cp1x, y: cp1y),
                    control2: CGPoint(x: cp2x, y: cp2y)
                )
            }
        }
        
        fillPath.addLine(to: CGPoint(x: usableWidth, y: usableHeight))
        fillPath.closeSubpath()
        
        let gradient = Gradient(colors: [
            Color.green.opacity(0.3),
            Color.yellow.opacity(0.2),
            Color.red.opacity(0.1)
        ])
        
        context.fill(fillPath, with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: usableHeight)
        ))
        
        let maxDB = points.map { $0.db }.max() ?? -60
        let curveColor = getQ3CurveColor(maxDB)
        
        context.stroke(curvePath, with: .color(curveColor), lineWidth: 2)
        context.stroke(curvePath, with: .color(curveColor.opacity(0.5)), lineWidth: 4)
    }
    
    private func drawPeakHold(context: GraphicsContext, size: CGSize) {
        let usableHeight = size.height - 30
        let usableWidth = size.width - 60
        let peaks = analyzer.peakHolds
        guard peaks.count > 1 else { return }
        
        var peakPath = Path()
        var points: [(x: CGFloat, y: CGFloat)] = []
        
        for i in 0..<peaks.count {
            let x = (CGFloat(i) / CGFloat(peaks.count - 1)) * usableWidth
            let db = magnitudeToCalibratedDB(peaks[i])
            let y = dbToY(db, height: usableHeight)
            points.append((x, y))
        }
        
        guard points.count > 2 else { return }
        
        peakPath.move(to: CGPoint(x: points[0].x, y: points[0].y))
        
        for i in 1..<points.count {
            let current = points[i]
            let previous = points[i - 1]
            
            if i == 1 {
                peakPath.addLine(to: CGPoint(x: current.x, y: current.y))
            } else {
                let previous2 = points[i - 2]
                
                let cp1x = previous.x + (current.x - previous2.x) / 6
                let cp1y = previous.y + (current.y - previous2.y) / 6
                
                let cp2x = current.x - (current.x - previous.x) / 3
                let cp2y = current.y - (current.y - previous.y) / 3
                
                peakPath.addCurve(
                    to: CGPoint(x: current.x, y: current.y),
                    control1: CGPoint(x: cp1x, y: cp1y),
                    control2: CGPoint(x: cp2x, y: cp2y)
                )
            }
        }
        
        context.stroke(peakPath, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
    }
    
    private func magnitudeToCalibratedDB(_ normalized: Float) -> Float {
        let db = (normalized * 60.0) - 60.0
        return db - referenceLevel
    }
    
    private func dbToY(_ db: Float, height: CGFloat) -> CGFloat {
        let dbRange = maxDB - minDB
        let normalizedPosition = (db - minDB) / dbRange
        return height * CGFloat(1.0 - normalizedPosition)
    }
    
    private func frequencyToX(_ frequency: Float, width: CGFloat) -> CGFloat {
        let minFreq = log10(Float(20.0))
        let maxFreq = log10(Float(20000.0))
        let logFreq = log10(frequency)
        
        let normalized = (logFreq - minFreq) / (maxFreq - minFreq)
        return width * CGFloat(normalized)
    }
    
    private func getQ3CurveColor(_ db: Float) -> Color {
        switch db {
        case ..<(-12):
            return Color(red: 0.2, green: 0.9, blue: 0.2)
        case -12..<(-3):
            return Color(red: 0.9, green: 0.9, blue: 0.2)
        case -3..<3:
            return Color(red: 0.9, green: 0.5, blue: 0.2)
        default:
            return Color(red: 0.9, green: 0.2, blue: 0.2)
        }
    }
}
