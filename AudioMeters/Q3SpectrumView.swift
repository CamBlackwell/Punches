import Accelerate
import MetalKit
import SwiftUI

// MARK: - Q3Vertex

/// Swift mirror of the Metal `Vertex` struct (float2 position + float4 color).
/// Memory layout must stay identical to the Metal declaration.
public struct Q3Vertex {
  var position: SIMD2<Float>
  var color: SIMD4<Float>

  init(_ x: Float, _ y: Float, color: SIMD4<Float>) {
    position = SIMD2(x, y)
    self.color = color
  }
}

// MARK: - Q3SpectrumView

/// MiniMeters-style spectrum analyzer backed by a Metal renderer.
///
/// Displays a stereo (L+R) magnitude spectrum in dBFS on a logarithmic frequency
/// axis. Tap or drag to inspect the frequency and level at any point.
/// An A-weighting toggle is accessible in the top-right corner.
struct Q3SpectrumView: View {

  @ObservedObject var analyser: UnifiedAudioAnalyser

  /// Normalised [0, 1] horizontal position of the inspect cursor. `nil` when inactive.
  @State private var inspectFraction: CGFloat?

  init(analyser: UnifiedAudioAnalyser) {
    self.analyser = analyser
  }

  public var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {

        // MARK: Metal renderer
        Q3MetalViewRepresentable(
          analyser: analyser,
          inspectFraction: inspectFraction
        )

        // MARK: Axis labels (SwiftUI for crisp text at every resolution)
        Q3AxisLabels(size: geo.size)

        // MARK: Inspect readout pill
        if let fraction = inspectFraction {
          Q3InspectOverlay(
            fraction: fraction,
            size: geo.size,
            analyser: analyser
          )
        }

        // MARK: Enhanced-mode toggle (top-right corner)
        HStack {
          Spacer()
          Button {
            analyser.q3EnhancedMode.toggle()
          } label: {
            HStack(spacing: 3) {
              Image(
                systemName: analyser.q3EnhancedMode
                  ? "waveform.badge.magnifyingglass" : "waveform"
              )
              .font(.system(size: 9, weight: .medium))
              Text(analyser.q3EnhancedMode ? "A-WT" : "FLAT")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(
              analyser.q3EnhancedMode
                ? Color.orange
                : Color.white.opacity(0.28)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 4))
          }
          .padding(6)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let clamped = min(max(value.location.x / geo.size.width, 0), 1)
            inspectFraction = clamped
          }
          .onEnded { _ in
            withAnimation(.easeOut(duration: 0.45)) {
              inspectFraction = nil
            }
          }
      )
    }
    .background(Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Q3MetalViewRepresentable

private struct Q3MetalViewRepresentable: UIViewRepresentable {

  @ObservedObject var analyser: UnifiedAudioAnalyser
  let inspectFraction: CGFloat?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView()
    guard let device = MTLCreateSystemDefaultDevice() else { return view }

    view.device = device
    view.delegate = context.coordinator.renderer
    view.preferredFramesPerSecond = 60
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.framebufferOnly = true
    view.isOpaque = false
    view.backgroundColor = .clear
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)

    context.coordinator.renderer.setup(device: device, view: view)
    return view
  }

  func updateUIView(_ uiView: MTKView, context: Context) {
    let r = context.coordinator.renderer
    r.bands = analyser.q3SpectrumBands
    r.peaks = analyser.q3PeakHolds
    r.enhancedMode = analyser.q3EnhancedMode
    r.inspectFraction = inspectFraction.map(Float.init)
  }

  final class Coordinator {
    let renderer = Q3MetalRenderer()
  }
}

// MARK: - Q3MetalRenderer

/// Renders the spectrum using Metal draw calls. All geometry is built in pixel
/// space (0…width, 0…height) and converted to NDC by `q3VertexShader`.
final class Q3MetalRenderer: NSObject, MTKViewDelegate {

  // Data written by the SwiftUI layer (main thread) and read each draw call.
  var bands: [Float] = []
  var peaks: [Float] = []
  var enhancedMode: Bool = false
  var inspectFraction: Float?

  private var device: MTLDevice?
  private var commandQueue: MTLCommandQueue?

  /// Used for grid lines, fills, peak holds, and the inspect hairline.
  private var gridPipelineState: MTLRenderPipelineState?
  /// Used for the spectrum curve line — adds a subtle emission via `q3GlowFragmentShader`.
  private var linePipelineState: MTLRenderPipelineState?

  // MARK: Colour palette

  private enum Palette {
    // Flat mode — cyan
    static let flatLine = SIMD4<Float>(0.00, 0.84, 1.00, 1.00)
    static let flatFillTop = SIMD4<Float>(0.00, 0.72, 0.92, 0.44)
    static let flatFillBottom = SIMD4<Float>(0.00, 0.36, 0.65, 0.00)
    // A-weighted mode — amber
    static let warmLine = SIMD4<Float>(1.00, 0.62, 0.08, 1.00)
    static let warmFillTop = SIMD4<Float>(1.00, 0.55, 0.06, 0.40)
    static let warmFillBottom = SIMD4<Float>(0.80, 0.28, 0.00, 0.00)
    // Grid
    static let grid = SIMD4<Float>(1.0, 1.0, 1.0, 0.07)
    static let gridZeroDBFS = SIMD4<Float>(1.0, 1.0, 1.0, 0.18)
    // Peak hold ticks
    static let peakHold = SIMD4<Float>(1.0, 1.0, 1.0, 0.70)
    // Inspect hairline
    static let inspect = SIMD4<Float>(1.0, 1.0, 1.0, 0.42)
  }

  // MARK: Setup

  func setup(device: MTLDevice, view: MTKView) {
    self.device = device
    commandQueue = device.makeCommandQueue()
    buildPipelines(device: device, pixelFormat: view.colorPixelFormat)
  }

  private func buildPipelines(device: MTLDevice, pixelFormat: MTLPixelFormat) {
    guard let library = device.makeDefaultLibrary() else {
      print("Q3MetalRenderer: default Metal library not found")
      return
    }

    /// Configures standard source-over alpha blending on a pipeline descriptor.
    let applyBlending: (MTLRenderPipelineDescriptor) -> Void = { desc in
      guard let att = desc.colorAttachments[0] else { return }
      att.isBlendingEnabled = true
      att.sourceRGBBlendFactor = .sourceAlpha
      att.destinationRGBBlendFactor = .oneMinusSourceAlpha
      att.sourceAlphaBlendFactor = .one
      att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let gridDesc = MTLRenderPipelineDescriptor()
    gridDesc.vertexFunction = library.makeFunction(name: "q3VertexShader")
    gridDesc.fragmentFunction = library.makeFunction(name: "gridFragmentShader")
    gridDesc.colorAttachments[0]?.pixelFormat = pixelFormat
    applyBlending(gridDesc)

    let lineDesc = MTLRenderPipelineDescriptor()
    lineDesc.vertexFunction = library.makeFunction(name: "q3VertexShader")
    lineDesc.fragmentFunction = library.makeFunction(name: "q3GlowFragmentShader")
    lineDesc.colorAttachments[0]?.pixelFormat = pixelFormat
    applyBlending(lineDesc)

    do {
      gridPipelineState = try device.makeRenderPipelineState(descriptor: gridDesc)
      linePipelineState = try device.makeRenderPipelineState(descriptor: lineDesc)
    } catch {
      print("Q3MetalRenderer: pipeline build error: \(error)")
    }
  }

  // MARK: MTKViewDelegate

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard
      let gridPipeline = gridPipelineState,
      let linePipeline = linePipelineState,
      let queue = commandQueue,
      let drawable = view.currentDrawable,
      let passDesc = view.currentRenderPassDescriptor,
      let commandBuffer = queue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc)
    else { return }

    let viewSize = view.drawableSize
    var viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))

    // Grid lines (horizontal dB + vertical frequency)
    encoder.setRenderPipelineState(gridPipeline)
    drawGrid(encoder: encoder, viewport: &viewport, size: viewSize)

    let bandSnapshot = bands
    let peakSnapshot = peaks

    if !bandSnapshot.isEmpty {
      // Gradient fill under the curve
      drawFill(
        encoder: encoder, viewport: &viewport,
        bands: bandSnapshot, size: viewSize)

      // Spectrum curve line (glow pipeline)
      encoder.setRenderPipelineState(linePipeline)
      drawLine(
        encoder: encoder, viewport: &viewport,
        bands: bandSnapshot, size: viewSize)

      // Peak hold ticks
      encoder.setRenderPipelineState(gridPipeline)
      drawPeaks(
        encoder: encoder, viewport: &viewport,
        peaks: peakSnapshot, size: viewSize)
    }

    // Inspect hairline
    if let fraction = inspectFraction {
      drawInspectLine(
        encoder: encoder, viewport: &viewport,
        fraction: fraction, size: viewSize)
    }

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  // MARK: Coordinate helpers

  /// Maps a band index to a pixel-space X coordinate.
  /// Bands are already log-spaced, so linear mapping gives a logarithmic axis.
  private func bandToX(_ index: Int, count: Int, width: Float) -> Float {
    guard count > 1 else { return width / 2 }
    return Float(index) / Float(count - 1) * width
  }

  /// Maps a normalised level [0, 1] to a pixel-space Y coordinate (0 = top).
  private func levelToY(_ level: Float, height: Float) -> Float {
    (1.0 - level) * height
  }

  /// Maps a frequency in Hz to a pixel-space X coordinate on a log scale.
  private func freqToX(_ hz: Float, width: Float) -> Float {
    let minLog = log10(Float(20))
    let maxLog = log10(Float(20_000))
    let fraction = (log10(hz) - minLog) / (maxLog - minLog)
    return fraction * width
  }

  /// Maps a dBFS value to a pixel-space Y coordinate.
  /// Display range is −90 dBFS (bottom) to 0 dBFS (top).
  private func dBToY(_ dB: Float, height: Float) -> Float {
    let normalised = (dB + 90.0) / 90.0
    return (1.0 - normalised) * height
  }

  // MARK: Buffer submission

  private func submit(
    vertices: [Q3Vertex],
    encoder: MTLRenderCommandEncoder,
    viewport: inout SIMD2<Float>,
    primitive: MTLPrimitiveType
  ) {
    guard !vertices.isEmpty, let device = device else { return }
    guard let buffer = device.makeBuffer(
      bytes: vertices,
      length: vertices.count * MemoryLayout<Q3Vertex>.stride,
      options: .storageModeShared
    ) else { return }

    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
  }

  // MARK: Draw passes

  private func drawGrid(
    encoder: MTLRenderCommandEncoder,
    viewport: inout SIMD2<Float>,
    size: CGSize
  ) {
    let w = Float(size.width)
    let h = Float(size.height)
    var vertices: [Q3Vertex] = []

    // Horizontal dBFS lines
    for dB: Float in [-80, -70, -60, -50, -40, -30, -20, -10] {
      let y = dBToY(dB, height: h)
      vertices.append(Q3Vertex(0, y, color: Palette.grid))
      vertices.append(Q3Vertex(w, y, color: Palette.grid))
    }
    // 0 dBFS reference line — slightly brighter
    let yZero = dBToY(0, height: h)
    vertices.append(Q3Vertex(0, yZero, color: Palette.gridZeroDBFS))
    vertices.append(Q3Vertex(w, yZero, color: Palette.gridZeroDBFS))

    // Vertical frequency lines
    for hz: Float in [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] {
      let x = freqToX(hz, width: w)
      vertices.append(Q3Vertex(x, 0, color: Palette.grid))
      vertices.append(Q3Vertex(x, h, color: Palette.grid))
    }

    submit(vertices: vertices, encoder: encoder, viewport: &viewport, primitive: .line)
  }

  private func drawFill(
    encoder: MTLRenderCommandEncoder,
    viewport: inout SIMD2<Float>,
    bands: [Float],
    size: CGSize
  ) {
    let n = bands.count
    guard n > 1 else { return }
    let w = Float(size.width)
    let h = Float(size.height)

    let topColor = enhancedMode ? Palette.warmFillTop : Palette.flatFillTop
    let botColor = enhancedMode ? Palette.warmFillBottom : Palette.flatFillBottom

    // Triangle strip: top vertex at curve height + bottom vertex at floor, per band.
    var vertices: [Q3Vertex] = []
    vertices.reserveCapacity(n * 2)

    for i in 0..<n {
      let x = bandToX(i, count: n, width: w)
      let y = levelToY(bands[i], height: h)
      vertices.append(Q3Vertex(x, y, color: topColor))
      vertices.append(Q3Vertex(x, h, color: botColor))
    }

    submit(
      vertices: vertices, encoder: encoder, viewport: &viewport,
      primitive: .triangleStrip)
  }

  private func drawLine(
    encoder: MTLRenderCommandEncoder,
    viewport: inout SIMD2<Float>,
    bands: [Float],
    size: CGSize
  ) {
    let n = bands.count
    guard n > 1 else { return }
    let w = Float(size.width)
    let h = Float(size.height)

    let lineColor = enhancedMode ? Palette.warmLine : Palette.flatLine

    var vertices: [Q3Vertex] = []
    vertices.reserveCapacity(n)

    for i in 0..<n {
      let x = bandToX(i, count: n, width: w)
      let y = levelToY(bands[i], height: h)
      vertices.append(Q3Vertex(x, y, color: lineColor))
    }

    submit(vertices: vertices, encoder: encoder, viewport: &viewport, primitive: .lineStrip)
  }

  private func drawPeaks(
    encoder: MTLRenderCommandEncoder,
    viewport: inout SIMD2<Float>,
    peaks: [Float],
    size: CGSize
  ) {
    let n = peaks.count
    guard n > 1 else { return }
    let w = Float(size.width)
    let h = Float(size.height)
    // Each peak tick spans 40% of one band's width
    let halfTick = (w / Float(n - 1)) * 0.20

    var vertices: [Q3Vertex] = []

    for i in 0..<n {
      guard peaks[i] > 0.012 else { continue }
      let x = bandToX(i, count: n, width: w)
      let y = levelToY(peaks[i], height: h)
      vertices.append(Q3Vertex(x - halfTick, y, color: Palette.peakHold))
      vertices.append(Q3Vertex(x + halfTick, y, color: Palette.peakHold))
    }

    guard !vertices.isEmpty else { return }
    submit(vertices: vertices, encoder: encoder, viewport: &viewport, primitive: .line)
  }

  private func drawInspectLine(
    encoder: MTLRenderCommandEncoder,
    viewport: inout SIMD2<Float>,
    fraction: Float,
    size: CGSize
  ) {
    let x = fraction * Float(size.width)
    let h = Float(size.height)
    let vertices: [Q3Vertex] = [
      Q3Vertex(x, 0, color: Palette.inspect),
      Q3Vertex(x, h, color: Palette.inspect),
    ]
    submit(vertices: vertices, encoder: encoder, viewport: &viewport, primitive: .line)
  }
}

// MARK: - Q3AxisLabels

/// Renders frequency labels along the bottom edge and dBFS labels along the
/// right edge using SwiftUI text, which is always crisp regardless of display scale.
private struct Q3AxisLabels: View {

  let size: CGSize

  private let frequencyMarkers: [(label: String, hz: Float)] = [
    ("20", 20), ("50", 50), ("100", 100), ("200", 200), ("500", 500),
    ("1k", 1_000), ("2k", 2_000), ("5k", 5_000), ("10k", 10_000), ("20k", 20_000),
  ]

  private let dBMarkers: [Float] = [0, -10, -20, -30, -40, -50, -60, -70, -80]

  private func xForFrequency(_ hz: Float) -> CGFloat {
    let minLog = log10(Float(20))
    let maxLog = log10(Float(20_000))
    return CGFloat((log10(hz) - minLog) / (maxLog - minLog)) * size.width
  }

  private func yForDB(_ dB: Float) -> CGFloat {
    (1.0 - CGFloat((dB + 90.0) / 90.0)) * size.height
  }

  var body: some View {
    ZStack {
      // Frequency labels — bottom edge
      ForEach(frequencyMarkers, id: \.hz) { marker in
        Text(marker.label)
          .font(.system(size: 7.5, weight: .medium, design: .monospaced))
          .foregroundColor(.white.opacity(0.28))
          .position(x: xForFrequency(marker.hz), y: size.height - 7)
      }

      // dBFS labels — right edge
      ForEach(dBMarkers, id: \.self) { dB in
        Text("\(Int(dB))")
          .font(.system(size: 7.5, weight: .medium, design: .monospaced))
          .foregroundColor(.white.opacity(0.28))
          .position(x: size.width - 11, y: yForDB(dB))
      }
    }
  }
}

// MARK: - Q3InspectOverlay

/// A floating readout pill showing the frequency and dBFS level at the
/// current inspect cursor position. Clamped so it never overflows the view.
private struct Q3InspectOverlay: View {

  let fraction: CGFloat
  let size: CGSize
  let analyser: UnifiedAudioAnalyser

  private var inspectInfo: (frequency: Float, dBFS: Float) {
    let minLog = log10(Float(20))
    let maxLog = log10(Float(20_000))
    let logFreq = minLog + Float(fraction) * (maxLog - minLog)
    let frequency = pow(10.0, logFreq)

    let bands = analyser.q3SpectrumBands
    guard !bands.isEmpty else { return (frequency, -90) }
    let index = min(
      Int(fraction * CGFloat(bands.count - 1)),
      bands.count - 1)
    let value = bands[max(0, index)]
    // Reverse the normalisation: value ∈ [0,1] → dBFS ∈ [-90, 0]
    let dBFS = value * 90.0 - 90.0

    return (frequency, dBFS)
  }

  private var frequencyLabel: String {
    let f = inspectInfo.frequency
    return f >= 1_000
      ? String(format: "%.2f kHz", f / 1_000)
      : String(format: "%.0f Hz", f)
  }

  var body: some View {
    let cursorX = fraction * size.width
    let info = inspectInfo
    // Keep the pill inside the view horizontally
    let pillX = min(max(cursorX, 46), size.width - 46)

    VStack(spacing: 2) {
      Text(frequencyLabel)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundColor(.white)
      Text(String(format: "%.1f dBFS", info.dBFS))
        .font(.system(size: 9, weight: .regular, design: .monospaced))
        .foregroundColor(.white.opacity(0.62))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .position(x: pillX, y: 22)
  }
}
