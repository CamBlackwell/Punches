import AVFoundation
import MetalKit
import os.lock
import SwiftUI

// MARK: - GoniometerView

/// Metal-backed multi-band Lissajous goniometer, inspired by MiniMeters.
///
/// The incoming L/R signal is split into three frequency bands using
/// first-order IIR low-pass filters:
///
///   • Bass  (0–300 Hz)    → orange  — usually a narrow vertical cluster (mono)
///   • Mids  (300–3 kHz)   → cyan    — moderate width, melodic content
///   • Highs (3–20 kHz)    → violet  — often wide/diffuse (cymbals, air)
///
/// Each band produces its own completely independent Lissajous scatter plot.
/// The three plots are overlaid on the same canvas with additive glow blending,
/// so you can read the stereo behaviour of each frequency range at a glance.
struct GoniometerView: View {

  @ObservedObject var analyzer: UnifiedAudioAnalyser
  @EnvironmentObject var theme: ThemeManager

  private let zoomSteps: [Float] = [1, 2, 4, 8]
  @State private var zoomIndex: Int = 0
  private var zoomGain: Float { zoomSteps[zoomIndex] }



  var body: some View {
    VStack(spacing: 6) {

      // MARK: Metal canvas
      ZStack(alignment: .topTrailing) {
        GoniometerMetalViewRepresentable(
          analyzer: analyzer,
          zoomGain: zoomGain
        )
        .overlay(GoniometerAxisOverlay())

        // MARK: Zoom control — top-right corner
        HStack(spacing: 0) {
          Button {
            if zoomIndex > 0 { zoomIndex -= 1 }
          } label: {
            Image(systemName: "minus")
              .font(.system(size: 9, weight: .semibold))
              .frame(width: 22, height: 22)
          }
          .disabled(zoomIndex == 0)

          Text("×\(Int(zoomGain))")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .frame(width: 24)

          Button {
            if zoomIndex < zoomSteps.count - 1 { zoomIndex += 1 }
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 9, weight: .semibold))
              .frame(width: 22, height: 22)
          }
          .disabled(zoomIndex == zoomSteps.count - 1)
        }
        .foregroundColor(zoomGain > 1 ? Color.orange : Color.white.opacity(0.30))
        .background(Color.black.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(6)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // MARK: Phase correlation bar (SwiftUI)
      phaseCorrelationBar
    }
    .padding(.horizontal)
  }

  // MARK: Phase correlation bar

  private var phaseCorrelationBar: some View {
    VStack(spacing: 2) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.08))

          let normalised = CGFloat((analyzer.phaseCorrelation + 1) / 2)
          RoundedRectangle(cornerRadius: 3)
            .fill(
              LinearGradient(
                stops: [
                  .init(color: .red,    location: 0.00),
                  .init(color: .orange, location: 0.25),
                  .init(color: .yellow, location: 0.45),
                  .init(color: .green,  location: 0.65),
                  .init(color: .green,  location: 1.00),
                ],
                startPoint: .leading,
                endPoint: .trailing)
            )
            .frame(width: geo.size.width * normalised)
            .animation(.linear(duration: 0.05), value: normalised)

          // Centre reference tick
          Rectangle()
            .fill(Color.white.opacity(0.45))
            .frame(width: 1.5)
            .offset(x: geo.size.width / 2 - 0.75)
        }
      }
      .frame(height: 6)
      .clipShape(RoundedRectangle(cornerRadius: 3))

      HStack {
        Text("−1").frame(maxWidth: .infinity, alignment: .leading)
        Text("0").frame(maxWidth: .infinity, alignment: .center)
        Text("+1").frame(maxWidth: .infinity, alignment: .trailing)
      }
      .font(.system(size: 7.5, weight: .medium, design: .monospaced))
      .foregroundColor(.white.opacity(0.25))
    }
  }
}

// MARK: - Axis Labels Overlay

/// Labels the cardinal and diagonal goniometer axes.
///
/// Coordinate mapping (matches Metal renderer):
///   side → horizontal  (right = +S)
///   mid  → vertical    (up    = +M)
///   pure L signal plots upper-right, pure R plots upper-left.
private struct GoniometerAxisOverlay: View {
  var body: some View {
    GeometryReader { geo in
      let w      = geo.size.width
      let h      = geo.size.height
      let cx     = w / 2
      let cy     = h / 2
      let radius = min(w, h) / 2 - 14
      let diagR  = radius * 0.87
      let d      = diagR * 0.707   // cos/sin 45°

      ZStack {
        Text("+M")
          .position(x: cx, y: cy - radius + 11)
        Text("−M")
          .position(x: cx, y: cy + radius - 11)
        Text("L")
          .position(x: cx + d - 1, y: cy - d + 9)
        Text("R")
          .position(x: cx - d + 1, y: cy - d + 9)
        Text("+S")
          .position(x: cx + radius - 13, y: cy)
        Text("−S")
          .position(x: cx - radius + 13, y: cy)
      }
      .font(.system(size: 7.5, weight: .medium, design: .monospaced))
      .foregroundColor(.white.opacity(0.22))
    }
    .allowsHitTesting(false)
  }
}

// MARK: - GoniometerMetalViewRepresentable

private struct GoniometerMetalViewRepresentable: UIViewRepresentable {

  @ObservedObject var analyzer: UnifiedAudioAnalyser
  let zoomGain: Float

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
    context.coordinator.renderer.updateSamples(
      left:       analyzer.leftSamples,
      right:      analyzer.rightSamples,
      zoom:       zoomGain,
      sampleRate: Float(AVAudioSession.sharedInstance().sampleRate)
    )
  }

  final class Coordinator {
    let renderer = GoniometerMetalRenderer()
  }
}

// MARK: - GonioVertex (Swift mirror of Metal struct)

/// Must stay byte-for-byte identical to the Metal `GonioVertex` declaration
/// in Shaders.metal: float2 position + float4 color + float age = 36 bytes.
private struct GonioVertex {
  var position: SIMD2<Float>
  var color:    SIMD4<Float>
  var age:      Float

  init() { position = .zero; color = .zero; age = 0 }

  init(position: SIMD2<Float>, color: SIMD4<Float>, age: Float) {
    self.position = position
    self.color    = color
    self.age      = age
  }
}

// MARK: - GonioGlowUniforms

/// Swift mirror of the Metal `GonioGlowUniforms` struct — exactly 8 bytes.
/// Passed as buffer(2) to `gonioGlowPointVertexShader`.
private struct GonioGlowUniforms {
  var pointSizeScale: Float
  var alphaScale:     Float
}

// MARK: - GoniometerMetalRenderer

/// Renders the Lissajous goniometer with three visual layers per frame:
///
/// 1. **Guide pass** — concentric rings (with frequency-range tints),
///    M/S cross-hair, and L/R 45° diagonals.
/// 2. **Scatter pass** — one glow point sprite per sample drawn in three
///    depth layers (wide soft bloom → medium halo → crisp core).
/// 3. **Trail pass** — the 150 most-recent points rendered as a dense
///    glow point cloud that reads as a phosphor-decay trail.
final class GoniometerMetalRenderer: NSObject, MTKViewDelegate {

  // MARK: Thread-safe sample snapshot
  //
  // updateUIView (main thread) writes; draw(in:) (Metal render thread) reads.
  // All cross-thread access is guarded with os_unfair_lock.
  //
  // The incoming full-range L/R PCM is split here into three frequency bands
  // using cascaded first-order IIR low-pass filters:
  //
  //   LP₃₀₀  (cutoff ~300 Hz) → bass band
  //   LP₃ₖ   (cutoff ~3 kHz)  → bass + mid combined
  //   mid  = LP₃ₖ − LP₃₀₀
  //   high = original − LP₃ₖ
  //
  // Each band gets its own independent L/R pair from which M/S coordinates
  // are computed in the draw pass, producing three genuinely separate
  // Lissajous shapes — exactly as MiniMeters' Multi-Band stereometer does.

  private var _lock          = os_unfair_lock()
  private var _bassLeft:     [Float] = []
  private var _bassRight:    [Float] = []
  private var _midLeft:      [Float] = []
  private var _midRight:     [Float] = []
  private var _highLeft:     [Float] = []
  private var _highRight:    [Float] = []
  private var _zoomGain:     Float   = 1.0

  // Persistent IIR filter state — must survive across updateSamples calls
  // so the filters have memory and don't restart each frame.
  private var _lp300L: Float = 0;  private var _lp300R: Float = 0
  private var _lp3kL:  Float = 0;  private var _lp3kR:  Float = 0

  /// Call only from the main thread (updateUIView).
  /// Runs two cascaded low-pass filters over the new samples and stores
  /// three band-split L/R arrays for the render thread to consume.
  func updateSamples(left: [Float], right: [Float],
                     zoom: Float, sampleRate: Float) {
    let count = min(left.count, right.count)
    guard count > 0 else { return }

    // IIR coefficients: α = 1 − exp(−2π·fc/fs)
    let sr    = max(sampleRate, 8000)   // guard against zero at startup
    let a300  = 1 - exp(-2 * Float.pi * 300  / sr)
    let a3k   = 1 - exp(-2 * Float.pi * 3000 / sr)

    var bL = [Float](repeating: 0, count: count)
    var bR = [Float](repeating: 0, count: count)
    var mL = [Float](repeating: 0, count: count)
    var mR = [Float](repeating: 0, count: count)
    var hL = [Float](repeating: 0, count: count)
    var hR = [Float](repeating: 0, count: count)

    for i in 0..<count {
      _lp300L = _lp300L + a300 * (left[i]  - _lp300L)
      _lp300R = _lp300R + a300 * (right[i] - _lp300R)
      _lp3kL  = _lp3kL  + a3k  * (left[i]  - _lp3kL)
      _lp3kR  = _lp3kR  + a3k  * (right[i] - _lp3kR)

      bL[i] = _lp300L
      bR[i] = _lp300R
      mL[i] = _lp3kL - _lp300L
      mR[i] = _lp3kR - _lp300R
      hL[i] = left[i]  - _lp3kL
      hR[i] = right[i] - _lp3kR
    }

    os_unfair_lock_lock(&_lock)
    _bassLeft  = bL;  _bassRight  = bR
    _midLeft   = mL;  _midRight   = mR
    _highLeft  = hL;  _highRight  = hR
    _zoomGain  = zoom
    os_unfair_lock_unlock(&_lock)
  }

  /// Call only from the render thread (draw). Returns a consistent snapshot
  /// of all three band pairs.
  private func snapshot() -> (bassL: [Float], bassR: [Float],
                               midL:  [Float], midR:  [Float],
                               highL: [Float], highR: [Float],
                               gain:  Float) {
    os_unfair_lock_lock(&_lock)
    let bL = _bassLeft;  let bR = _bassRight
    let mL = _midLeft;   let mR = _midRight
    let hL = _highLeft;  let hR = _highRight
    let g  = _zoomGain
    os_unfair_lock_unlock(&_lock)
    return (bL, bR, mL, mR, hL, hR, g)
  }

  private var device:        MTLDevice?
  private var commandQueue:  MTLCommandQueue?
  private var guidePipeline: MTLRenderPipelineState?
  private var glowPipeline:  MTLRenderPipelineState?

  // MARK: Setup

  func setup(device: MTLDevice, view: MTKView) {
    self.device = device
    commandQueue = device.makeCommandQueue()
    buildPipelines(device: device, pixelFormat: view.colorPixelFormat)
  }

  private func buildPipelines(device: MTLDevice, pixelFormat: MTLPixelFormat) {
    guard let library = device.makeDefaultLibrary() else {
      print("GoniometerMetalRenderer: default Metal library not found")
      return
    }

    let addBlend: (MTLRenderPipelineDescriptor) -> Void = { desc in
      guard let att = desc.colorAttachments[0] else { return }
      att.isBlendingEnabled           = true
      att.sourceRGBBlendFactor        = .sourceAlpha
      att.destinationRGBBlendFactor   = .oneMinusSourceAlpha
      att.sourceAlphaBlendFactor      = .one
      att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let guideDesc = MTLRenderPipelineDescriptor()
    guideDesc.vertexFunction   = library.makeFunction(name: "gonioLineVertexShader")
    guideDesc.fragmentFunction = library.makeFunction(name: "gonioLineFragmentShader")
    guideDesc.colorAttachments[0]?.pixelFormat = pixelFormat
    addBlend(guideDesc)

    let glowDesc = MTLRenderPipelineDescriptor()
    glowDesc.vertexFunction   = library.makeFunction(name: "gonioGlowPointVertexShader")
    glowDesc.fragmentFunction = library.makeFunction(name: "gonioGlowFragmentShader")
    glowDesc.colorAttachments[0]?.pixelFormat = pixelFormat
    addBlend(glowDesc)

    do {
      guidePipeline = try device.makeRenderPipelineState(descriptor: guideDesc)
      glowPipeline  = try device.makeRenderPipelineState(descriptor: glowDesc)
    } catch {
      print("GoniometerMetalRenderer pipeline error: \(error)")
    }
  }

  // MARK: MTKViewDelegate

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard
      let guide     = guidePipeline,
      let glow      = glowPipeline,
      let queue     = commandQueue,
      let drawable  = view.currentDrawable,
      let passDesc  = view.currentRenderPassDescriptor,
      let cmdBuffer = queue.makeCommandBuffer(),
      let encoder   = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc)
    else { return }

    let size = view.drawableSize
    var vp   = SIMD2<Float>(Float(size.width), Float(size.height))

    // Guide layer: concentric rings + axis lines
    encoder.setRenderPipelineState(guide)
    drawGuides(encoder: encoder, vp: &vp, size: size)

    let snap = snapshot()
    let gain = snap.gain

    // Three independent Lissajous scatter plots — one per frequency band.
    // Each uses its own filtered L/R data so the shapes are genuinely different.
    //   Bass  → orange   (0–300 Hz, typically narrow/vertical = mono)
    //   Mids  → cyan     (300 Hz–3 kHz, melodic content)
    //   Highs → violet   (3–20 kHz, often wide/diffuse = stereo)
    if !snap.bassL.isEmpty {
      encoder.setRenderPipelineState(glow)

      // Draw bass last so it renders on top (it's the most "mono" and central,
      // so we want it readable through the wider mid/high clouds).
      drawBandCloud(encoder: encoder, vp: &vp, size: size,
                    left: snap.highL, right: snap.highR, gain: gain,
                    color: SIMD4(0.82, 0.25, 1.00, 1))   // violet — highs

      drawBandCloud(encoder: encoder, vp: &vp, size: size,
                    left: snap.midL, right: snap.midR, gain: gain,
                    color: SIMD4(0.08, 0.92, 1.00, 1))   // cyan — mids

      drawBandCloud(encoder: encoder, vp: &vp, size: size,
                    left: snap.bassL, right: snap.bassR, gain: gain,
                    color: SIMD4(1.00, 0.52, 0.06, 1))   // orange — bass
    }

    encoder.endEncoding()
    cmdBuffer.present(drawable)
    cmdBuffer.commit()
  }

  // MARK: Guide pass

  private func drawGuides(
    encoder: MTLRenderCommandEncoder,
    vp: inout SIMD2<Float>,
    size: CGSize
  ) {
    let w      = Float(size.width)
    let h      = Float(size.height)
    let cx     = w / 2
    let cy     = h / 2
    let radius = min(w, h) / 2 - 14

    // Inner ring (33 %) — subtle teal hint (lows register here)
    submitRing(cx: cx, cy: cy, r: radius * 0.33,
               color: SIMD4(0.15, 0.55, 0.70, 0.07),
               segments: 120, encoder: encoder, vp: &vp)

    // Middle ring (66 %) — subtle amber hint (mids / transients)
    submitRing(cx: cx, cy: cy, r: radius * 0.66,
               color: SIMD4(0.70, 0.42, 0.10, 0.07),
               segments: 120, encoder: encoder, vp: &vp)

    // Outer ring (100 %) — crisp white boundary
    submitRing(cx: cx, cy: cy, r: radius,
               color: SIMD4(1, 1, 1, 0.15),
               segments: 120, encoder: encoder, vp: &vp)

    // M axis — vertical reference (mono signal)
    submitSegment(from: SIMD2(cx, cy - radius), to: SIMD2(cx, cy + radius),
                  color: SIMD4(1, 1, 1, 0.12), encoder: encoder, vp: &vp)

    // S axis — horizontal reference (stereo width)
    submitSegment(from: SIMD2(cx - radius, cy), to: SIMD2(cx + radius, cy),
                  color: SIMD4(1, 1, 1, 0.07), encoder: encoder, vp: &vp)

    // L diagonal (upper-right ↔ lower-left) — pure Left signal trace
    let d = radius * 0.707
    submitSegment(from: SIMD2(cx + d, cy - d), to: SIMD2(cx - d, cy + d),
                  color: SIMD4(1, 1, 1, 0.18), encoder: encoder, vp: &vp)

    // R diagonal (upper-left ↔ lower-right) — pure Right signal trace
    submitSegment(from: SIMD2(cx - d, cy - d), to: SIMD2(cx + d, cy + d),
                  color: SIMD4(1, 1, 1, 0.18), encoder: encoder, vp: &vp)
  }

  // MARK: Smoothing helper

  /// 5-tap Gaussian moving average [1,4,6,4,1]/16 — removes single-sample
  /// jitter while preserving the shape of each band's Lissajous.
  private func smooth(_ a: [Float]) -> [Float] {
    guard a.count > 4 else { return a }
    var out = a
    for i in 2..<(a.count - 2) {
      out[i] = (a[i-2] + 4*a[i-1] + 6*a[i] + 4*a[i+1] + a[i+2]) / 16
    }
    return out
  }

  // MARK: Band cloud

  /// Draws one frequency band's independent Lissajous scatter + phosphor trail.
  ///
  /// `left`/`right` are **already band-filtered** arrays — the M/S coordinates
  /// computed here belong entirely to one frequency range.  Each band therefore
  /// produces its own distinct shape (bass = narrow vertical, highs = wide).
  ///
  /// Visual layers (back → front):
  ///   1. Wide bloom  — large low-alpha disc, gives glow haze
  ///   2. Soft halo   — medium disc, the shoulder of the glow
  ///   3. Bright core — small disc, the bright dot
  private func drawBandCloud(
    encoder: MTLRenderCommandEncoder,
    vp: inout SIMD2<Float>,
    size: CGSize,
    left: [Float], right: [Float],
    gain: Float,
    color: SIMD4<Float>
  ) {
    let count = min(left.count, right.count)
    guard count > 1, let device = device else { return }

    let center = SIMD2<Float>(Float(size.width) / 2, Float(size.height) / 2)
    let radius = min(Float(size.width), Float(size.height)) / 2 - 14

    // Apply gain and smooth each channel before building geometry
    var mids  = [Float](repeating: 0, count: count)
    var sides = [Float](repeating: 0, count: count)
    for i in 0..<count {
      mids[i]  = ((left[i] + right[i]) / 2) * gain
      sides[i] = ((left[i] - right[i]) / 2) * gain
    }
    mids  = smooth(mids)
    sides = smooth(sides)

    // Insert 8 lerp steps between each sample pair → 9× point density.
    // Dense overlapping Gaussian discs merge into continuous filled shapes.
    let steps = 8
    let totalVerts = (count - 1) * (steps + 1) + 1
    var verts = [GonioVertex]()
    verts.reserveCapacity(totalVerts)

    for i in 0..<count {
      let ageA = Float(i) / Float(count - 1)
      verts.append(GonioVertex(
        position: toPixel(mid: mids[i], side: sides[i], center: center, radius: radius),
        color:    color,
        age:      ageA))
      if i < count - 1 {
        let ageB = Float(i + 1) / Float(count - 1)
        for s in 1...steps {
          let f  = Float(s) / Float(steps + 1)
          let mi = mids[i]  + (mids[i+1]  - mids[i])  * f
          let si = sides[i] + (sides[i+1] - sides[i]) * f
          verts.append(GonioVertex(
            position: toPixel(mid: mi, side: si, center: center, radius: radius),
            color:    color,
            age:      ageA + (ageB - ageA) * f))
        }
      }
    }

    let vc = verts.count
    guard let buf = device.makeBuffer(bytes: verts,
                                      length: vc * MemoryLayout<GonioVertex>.stride,
                                      options: .storageModeShared) else { return }

    // Three glow layers: wide bloom → halo shoulder → bright core
    // Scale factors feed into the vertex shader formula:
    //   pointSize = (1.2 + age * 2.8) * scale
    // At age=1 (newest), core dots are ~11px, halo ~22px, bloom ~44px.
    let passes: [(scale: Float, alpha: Float)] = [
      (10.0, 0.012),   // bloom  — wide ambient haze
      ( 4.0, 0.055),   // halo   — soft shoulder
      ( 2.0, 0.900),   // core   — bright solid centre
    ]
    for pass in passes {
      var uni = GonioGlowUniforms(pointSizeScale: pass.scale, alphaScale: pass.alpha)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setVertexBytes(&vp,  length: MemoryLayout<SIMD2<Float>>.stride,      index: 1)
      encoder.setVertexBytes(&uni, length: MemoryLayout<GonioGlowUniforms>.stride, index: 2)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vc)
    }
  }

  // MARK: Coordinate mapping

  private func toPixel(
    mid: Float, side: Float,
    center: SIMD2<Float>, radius: Float
  ) -> SIMD2<Float> {
    SIMD2(center.x + side * radius, center.y - mid * radius)
  }

  // MARK: Guide geometry helpers

  private func submitRing(
    cx: Float, cy: Float, r: Float,
    color: SIMD4<Float>, segments: Int,
    encoder: MTLRenderCommandEncoder,
    vp: inout SIMD2<Float>
  ) {
    var verts = [Q3Vertex]()
    verts.reserveCapacity(segments + 1)
    for i in 0...segments {
      let a = Float(i) / Float(segments) * 2 * .pi
      verts.append(Q3Vertex(cx + r * cos(a), cy + r * sin(a), color: color))
    }
    submitLineStrip(vertices: verts, encoder: encoder, vp: &vp)
  }

  private func submitSegment(
    from a: SIMD2<Float>, to b: SIMD2<Float>,
    color: SIMD4<Float>,
    encoder: MTLRenderCommandEncoder,
    vp: inout SIMD2<Float>
  ) {
    let verts = [Q3Vertex(a.x, a.y, color: color),
                 Q3Vertex(b.x, b.y, color: color)]
    submitLineStrip(vertices: verts, encoder: encoder, vp: &vp)
  }

  private func submitLineStrip(
    vertices: [Q3Vertex],
    encoder: MTLRenderCommandEncoder,
    vp: inout SIMD2<Float>
  ) {
    guard !vertices.isEmpty, let device = device else { return }
    guard let buf = device.makeBuffer(
      bytes: vertices,
      length: vertices.count * MemoryLayout<Q3Vertex>.stride,
      options: .storageModeShared
    ) else { return }
    encoder.setVertexBuffer(buf, offset: 0, index: 0)
    encoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: vertices.count)
  }
}

// MARK: - Color → SIMD4

private extension Color {
  var simd: SIMD4<Float> {
    let ui = UIColor(self)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    return SIMD4(Float(r), Float(g), Float(b), Float(a))
  }
}
