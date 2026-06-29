import SwiftUI
import Combine

struct WaterShaderView: View {
    @EnvironmentObject var theme: ThemeManager
    @State private var time: Double = 0
    let timer = Timer.publish(every: 1/60, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(theme.waterColor)
                .colorEffect(
                    ShaderLibrary.waterEffect(
                        .float(time),
                        .float2(geo.size),
                        .color(theme.waterColor),
                        .float(Float(theme.waterIntensity))
                    )
                )
                .ignoresSafeArea()
                .onReceive(timer) { _ in
                    time += (1.0 / 60.0) * theme.waterSpeed
                }
        }
        .ignoresSafeArea() 
    }
}
