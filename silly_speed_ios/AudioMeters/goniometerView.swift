import SwiftUI

struct GoniometerView: View {
    @ObservedObject var analyzer: UnifiedAudioAnalyser
    @EnvironmentObject var theme: ThemeManager


    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 10

                var crosshairPath = Path()
                crosshairPath.move(to: CGPoint(x: center.x - radius, y: center.y))
                crosshairPath.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                crosshairPath.move(to: CGPoint(x: center.x, y: center.y - radius))
                crosshairPath.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(crosshairPath, with: .color(.white.opacity(0.2)), lineWidth: 1)

                var diagonalPath = Path()
                let diagLength = radius * 0.7
                diagonalPath.move(to: CGPoint(x: center.x - diagLength, y: center.y - diagLength))
                diagonalPath.addLine(to: CGPoint(x: center.x + diagLength, y: center.y + diagLength))
                diagonalPath.move(to: CGPoint(x: center.x - diagLength, y: center.y + diagLength))
                diagonalPath.addLine(to: CGPoint(x: center.x + diagLength, y: center.y - diagLength))
                context.stroke(diagonalPath, with: .color(.white.opacity(0.1)), lineWidth: 1)

                let leftSamples = analyzer.leftSamples
                let rightSamples = analyzer.rightSamples
                let count = min(leftSamples.count, rightSamples.count)

                for i in 0..<count {
                    let left = leftSamples[i]
                    let right = rightSamples[i]
                    let mid = (left + right) / 2
                    let side = (left - right) / 2
                    
                    let x = center.x + CGFloat(side) * radius
                    let y = center.y - CGFloat(mid) * radius
                    let alpha = Float(i) / Float(count)
                    
                    let pointRect = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
                    let pointPath = Path(ellipseIn: pointRect)
                    
                    let sideWeight = abs(side)
                    let midWeight = abs(mid)
                    
                    let totalWeight = sideWeight + midWeight
                    let red = totalWeight > 0 ? CGFloat(sideWeight / totalWeight) : 0.5
                    let blue = totalWeight > 0 ? CGFloat(midWeight / totalWeight) : 0.5
                    
                    
                    context.fill(
                        pointPath,
                                    with: .color(
                                        Color(red: Double(red), green: 0.5, blue: Double(blue))
                                            .opacity(Double(alpha * 0.8))
                                    )
                                )
                                
                                let range = max(0, count - 50)..<count
                                let points: [(CGPoint, Bool)] = range.map { i in
                                    let left = leftSamples[i]
                                    let right = rightSamples[i]
                                    let mid = (left + right) / 2
                                    let side = (left - right) / 2
                                    let x = center.x + CGFloat(side) * radius
                                    let y = center.y - CGFloat(mid) * radius
                                    let isMidDominant = abs(mid) > abs(side)
                                    return (CGPoint(x: x, y: y), isMidDominant)
                                }

                                func smoothPath(from pts: [CGPoint]) -> Path {
                                    var path = Path()
                                    guard pts.count > 1 else { return path }
                                    path.move(to: pts[0])
                                    for i in 1..<pts.count-1 {
                                        let mid = CGPoint(
                                            x: (pts[i].x + pts[i+1].x) / 2,
                                            y: (pts[i].y + pts[i+1].y) / 2
                                        )
                                        path.addQuadCurve(to: mid, control: pts[i])
                                    }
                                    path.addLine(to: pts.last!)
                                    return path
                                }

                                let midPoints = points.compactMap { $0.1 ? $0.0 : nil }
                                let sidePoints = points.compactMap { !$0.1 ? $0.0 : nil }

                    context.stroke(smoothPath(from: midPoints), with: .color(theme.gonioMidsColor.opacity(0.3)), lineWidth: 1)
                    context.stroke(smoothPath(from: sidePoints), with: .color(theme.gonioSidesColor.opacity(0.3)), lineWidth: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))

                    let normalizedValue = (analyzer.phaseCorrelation + 1) / 2
                    Rectangle()
                        .fill(phaseColor)
                        .frame(width: geometry.size.width * CGFloat(normalizedValue))

                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: geometry.size.width / 2)
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .padding(.horizontal)
    }

    private var phaseColor: Color {
        if analyzer.phaseCorrelation > 0.5 { return .green }
        else if analyzer.phaseCorrelation > 0 { return .yellow }
        else if analyzer.phaseCorrelation > -0.5 { return .orange }
        else { return .red }
    }
}
