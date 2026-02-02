import SwiftUI
import MetalKit

// MARK: - Display Mode Enum
enum SpectrumDisplayMode: String, CaseIterable {
    case stereo = "Stereo"
    case mid = "Mid"
    case side = "Side"
    case midSide = "Mid/Side"
}

// MARK: - Metal Renderer
class Q3MetalRenderer: NSObject, MTKViewDelegate {
    weak var analyzer: UnifiedAudioAnalyser?
    
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var gridPipelineState: MTLRenderPipelineState!
    private var fillPipelineState: MTLRenderPipelineState!
    
    var displayMode: SpectrumDisplayMode = .stereo
    var referenceLevel: Float = -12.0
    var showGainReduction: Bool = true
    var autoScale: Bool = true
    
    // Dynamic auto-scaling
    private var currentMinDB: Float = -60
    private var currentMaxDB: Float = 6
    private let defaultMinDB: Float = -60
    private let defaultMaxDB: Float = 6
    private var peakDB: Float = -60
    private let peakDecayRate: Float = 0.1
    private let scaleAttackRate: Float = 0.3
    private let scaleReleaseRate: Float = 0.05
    
    init(metalDevice: MTLDevice, analyzer: UnifiedAudioAnalyser) {
        self.device = metalDevice
        self.analyzer = analyzer
        super.init()
        
        setupMetal()
    }
    
    private func setupMetal() {
        commandQueue = device.makeCommandQueue()
        
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load Metal library")
        }
        
        // Spectrum curve pipeline
        setupCurvePipeline(library: library)
        
        // Grid pipeline
        setupGridPipeline(library: library)
        
        // Fill pipeline
        setupFillPipeline(library: library)
    }
    
    private func setupCurvePipeline(library: MTLLibrary) {
        let vertexFunction = library.makeFunction(name: "spectrumVertexShader")
        let fragmentFunction = library.makeFunction(name: "spectrumFragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Enable alpha blending
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create pipeline state: \(error)")
        }
    }
    
    private func setupGridPipeline(library: MTLLibrary) {
        let vertexFunction = library.makeFunction(name: "gridVertexShader")
        let fragmentFunction = library.makeFunction(name: "gridFragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            gridPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create grid pipeline state: \(error)")
        }
    }
    
    private func setupFillPipeline(library: MTLLibrary) {
        let vertexFunction = library.makeFunction(name: "fillVertexShader")
        let fragmentFunction = library.makeFunction(name: "fillFragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            fillPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create fill pipeline state: \(error)")
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }
    
    func draw(in view: MTKView) {
        guard let analyzer = analyzer,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        // Auto-scale based on current signal level
        if autoScale {
            updateAutoScale(analyzer: analyzer)
        } else {
            // Manual mode: use fixed range with reference level offset
            currentMaxDB = 6.0
            currentMinDB = -60.0
        }
        
        // Clear to black
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        
        let viewportSize = vector_float2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        
        // Draw grid
        drawGrid(encoder: renderEncoder, viewportSize: viewportSize)
        
        // Draw spectrum based on mode
        switch displayMode {
        case .stereo:
            drawSpectrum(encoder: renderEncoder, viewportSize: viewportSize,
                        bands: analyzer.spectrumBands, peaks: analyzer.peakHolds,
                        gainReduction: analyzer.gainReduction, yOffset: 0)
            
        case .mid:
            drawSpectrum(encoder: renderEncoder, viewportSize: viewportSize,
                        bands: analyzer.midSpectrumBands, peaks: analyzer.midPeakHolds,
                        gainReduction: analyzer.gainReduction, yOffset: 0)
            
        case .side:
            drawSpectrum(encoder: renderEncoder, viewportSize: viewportSize,
                        bands: analyzer.sideSpectrumBands, peaks: analyzer.sidePeakHolds,
                        gainReduction: analyzer.gainReduction, yOffset: 0)
            
        case .midSide:
            // Draw Mid on top half
            drawSpectrum(encoder: renderEncoder, viewportSize: vector_float2(viewportSize.x, viewportSize.y / 2),
                        bands: analyzer.midSpectrumBands, peaks: analyzer.midPeakHolds,
                        gainReduction: analyzer.gainReduction, yOffset: 0)
            
            // Draw Side on bottom half
            drawSpectrum(encoder: renderEncoder, viewportSize: vector_float2(viewportSize.x, viewportSize.y / 2),
                        bands: analyzer.sideSpectrumBands, peaks: analyzer.sidePeakHolds,
                        gainReduction: analyzer.gainReduction, yOffset: viewportSize.y / 2)
        }
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func updateAutoScale(analyzer: UnifiedAudioAnalyser) {
        // Get current max dB from spectrum
        let bands = displayMode == .mid ? analyzer.midSpectrumBands :
                   displayMode == .side ? analyzer.sideSpectrumBands :
                   analyzer.spectrumBands
        
        guard !bands.isEmpty else { return }
        
        let currentMaxMagnitude = bands.max() ?? 0
        let currentDB = magnitudeToCalibratedDB(currentMaxMagnitude)
        
        // Update peak with decay
        if currentDB > peakDB {
            peakDB = currentDB
        } else {
            peakDB -= peakDecayRate
        }
        
        // Calculate target range
        // Always show at least up to 0dB if signal is hot, or give headroom above peak
        let headroom: Float = 6.0
        let targetMaxDB: Float
        
        if peakDB > -12.0 {
            // Signal is hot, make sure we show 0dB or slightly above
            targetMaxDB = max(0.0, peakDB + headroom)
        } else {
            // Signal is quiet, just show some headroom above peak
            targetMaxDB = peakDB + headroom
        }
        
        // Cap at +6dB to leave some overhead
        let clampedMaxDB = min(targetMaxDB, 6.0)
        
        // Always show at least a 48dB range, up to 66dB
        let minRange: Float = 48.0
        let maxRange: Float = 66.0
        let targetRange = min(maxRange, max(minRange, clampedMaxDB - peakDB + 30.0))
        let targetMinDB = clampedMaxDB - targetRange
        
        // Smooth transition with faster attack, slower release
        if clampedMaxDB > currentMaxDB {
            currentMaxDB += (clampedMaxDB - currentMaxDB) * scaleAttackRate
        } else {
            currentMaxDB += (clampedMaxDB - currentMaxDB) * scaleReleaseRate
        }
        
        if targetMinDB < currentMinDB {
            currentMinDB += (targetMinDB - currentMinDB) * scaleAttackRate
        } else {
            currentMinDB += (targetMinDB - currentMinDB) * scaleReleaseRate
        }
    }
    
    private func drawGrid(encoder: MTLRenderCommandEncoder, viewportSize: vector_float2) {
        encoder.setRenderPipelineState(gridPipelineState)
        
        let usableHeight = viewportSize.y - 30
        let usableWidth = viewportSize.x - 60
        
        // Draw horizontal dB lines
        let dbStep: Float = 6.0
        var db = ceil(currentMinDB / dbStep) * dbStep
        
        while db <= currentMaxDB {
            let y = dbToY(db, height: usableHeight)
            let normalizedY = (y / viewportSize.y) * 2.0 - 1.0
            
            let opacity: Float
            let color: vector_float4
            
            if abs(db) < 0.1 {
                // 0 dB reference - bright and slightly red-tinted
                opacity = 0.8
                color = vector_float4(1.0, 0.3, 0.3, opacity)
            } else if Int(db) % 12 == 0 {
                // Major lines (every 12dB)
                opacity = 0.3
                color = vector_float4(1, 1, 1, opacity)
            } else {
                // Minor lines (every 6dB)
                opacity = 0.15
                color = vector_float4(1, 1, 1, opacity)
            }
            
            var vertices: [Vertex] = [
                Vertex(position: vector_float2(-1.0, normalizedY), color: color),
                Vertex(position: vector_float2(1.0, normalizedY), color: color)
            ]
            
            let vertexBuffer = device.makeBuffer(bytes: &vertices, length: vertices.count * MemoryLayout<Vertex>.stride, options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 2)
            
            db += dbStep
        }
        
        // Draw vertical frequency lines
        let frequencies: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        
        for freq in frequencies {
            let x = frequencyToX(freq, width: usableWidth)
            let normalizedX = (x / viewportSize.x) * 2.0 - 1.0
            
            let opacity: Float
            if freq == 100 || freq == 1000 || freq == 10000 {
                opacity = 0.3 // Major frequency lines
            } else {
                opacity = 0.15 // Minor frequency lines
            }
            
            var vertices: [Vertex] = [
                Vertex(position: vector_float2(normalizedX, -1.0), color: vector_float4(1, 1, 1, opacity)),
                Vertex(position: vector_float2(normalizedX, 1.0), color: vector_float4(1, 1, 1, opacity))
            ]
            
            let vertexBuffer = device.makeBuffer(bytes: &vertices, length: vertices.count * MemoryLayout<Vertex>.stride, options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 2)
        }
    }
    
    private func frequencyToX(_ frequency: Float, width: Float) -> Float {
        let minFreq = log10(20.0)
        let maxFreq = log10(20000.0)
        let logFreq = log10(Double(frequency))
        let fraction = Float((logFreq - minFreq) / (maxFreq - minFreq))
        return fraction * width
    }
    
    private func drawSpectrum(encoder: MTLRenderCommandEncoder, viewportSize: vector_float2,
                            bands: [Float], peaks: [Float], gainReduction: [Float], yOffset: Float) {
        guard bands.count > 1 else { return }
        
        let usableHeight = viewportSize.y - 30
        let usableWidth = viewportSize.x - 60
        
        // Calculate positions for each band
        var bandPositions: [(x: Float, y: Float, db: Float, gr: Float)] = []
        for i in 0..<bands.count {
            let x = (Float(i) / Float(bands.count - 1)) * usableWidth
            let db = magnitudeToCalibratedDB(bands[i])
            let y = dbToY(db, height: usableHeight) + yOffset
            let gr = i < gainReduction.count ? gainReduction[i] : 0.0
            bandPositions.append((x, y, db, gr))
        }
        
        // Get dynamic color
        let maxDB = bandPositions.map { $0.db }.max() ?? -60
        let color = getQ3CurveColor(maxDB)
        
        // Draw filled area
        drawFilledArea(encoder: encoder, viewportSize: viewportSize, bandPositions: bandPositions, color: color, yOffset: yOffset)
        
        // Generate interpolated curve vertices
        var vertices: [Vertex] = []
        let curveDetail = 10
        
        for i in 0..<(bandPositions.count - 1) {
            let p0 = i > 0 ? bandPositions[i - 1] : bandPositions[i]
            let p1 = bandPositions[i]
            let p2 = bandPositions[i + 1]
            let p3 = i < bandPositions.count - 2 ? bandPositions[i + 2] : p2
            
            for t in 0..<curveDetail {
                let t_norm = Float(t) / Float(curveDetail)
                let point = catmullRomInterpolate(p0: p0, p1: p1, p2: p2, p3: p3, t: t_norm)
                
                let normalizedX = (point.x / viewportSize.x) * 2.0 - 1.0
                let normalizedY = -(point.y / viewportSize.y) * 2.0 + 1.0
                
                vertices.append(Vertex(
                    position: vector_float2(normalizedX, normalizedY),
                    color: vector_float4(color.r, color.g, color.b, 1.0)
                ))
            }
        }
        
        if !vertices.isEmpty {
            encoder.setRenderPipelineState(pipelineState)
            
            // Multi-pass glow effect
            drawCurveLine(encoder: encoder, vertices: vertices, alpha: 0.3)
            drawCurveLine(encoder: encoder, vertices: vertices, alpha: 0.5)
            drawCurveLine(encoder: encoder, vertices: vertices, alpha: 1.0)
        }
        
        // Draw peak holds
        drawPeakHolds(encoder: encoder, viewportSize: viewportSize, peaks: peaks, yOffset: yOffset)
        
        // Draw gain reduction meters
        if showGainReduction {
            drawGainReductionMeters(encoder: encoder, viewportSize: viewportSize,
                                   bandPositions: bandPositions, yOffset: yOffset)
        }
    }
    
    private func drawCurveLine(encoder: MTLRenderCommandEncoder, vertices: [Vertex], alpha: Float) {
        var glowVertices = vertices.map { vertex in
            var v = vertex
            v.color.w *= alpha
            return v
        }
        
        let vertexBuffer = device.makeBuffer(bytes: &glowVertices,
                                            length: glowVertices.count * MemoryLayout<Vertex>.stride,
                                            options: [])
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: glowVertices.count)
    }
    
    private func drawFilledArea(encoder: MTLRenderCommandEncoder, viewportSize: vector_float2,
                               bandPositions: [(x: Float, y: Float, db: Float, gr: Float)],
                               color: (r: Float, g: Float, b: Float, a: Float), yOffset: Float) {
        encoder.setRenderPipelineState(fillPipelineState)
        
        var fillVertices: [Vertex] = []
        let usableHeight = viewportSize.y - 30
        let bottomY = -((usableHeight + yOffset) / viewportSize.y) * 2.0 + 1.0
        
        for pos in bandPositions {
            let normalizedX = (pos.x / viewportSize.x) * 2.0 - 1.0
            let normalizedY = -(pos.y / viewportSize.y) * 2.0 + 1.0
            
            let gradient_t = (pos.y - yOffset) / usableHeight
            let fillColor = vector_float4(
                color.r,
                color.g * (1.0 - gradient_t * 0.5),
                color.b,
                0.15 * (1.0 - gradient_t * 0.5)
            )
            
            fillVertices.append(Vertex(position: vector_float2(normalizedX, normalizedY), color: fillColor))
            fillVertices.append(Vertex(position: vector_float2(normalizedX, bottomY), color: vector_float4(0, 0, 0, 0)))
        }
        
        if !fillVertices.isEmpty {
            let vertexBuffer = device.makeBuffer(bytes: &fillVertices,
                                                length: fillVertices.count * MemoryLayout<Vertex>.stride,
                                                options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: fillVertices.count)
        }
    }
    
    private func drawPeakHolds(encoder: MTLRenderCommandEncoder, viewportSize: vector_float2, peaks: [Float], yOffset: Float) {
        guard peaks.count > 1 else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        
        let usableHeight = viewportSize.y - 30
        let usableWidth = viewportSize.x - 60
        
        var vertices: [Vertex] = []
        
        for i in 0..<peaks.count {
            let x = (Float(i) / Float(peaks.count - 1)) * usableWidth
            let db = magnitudeToCalibratedDB(peaks[i])
            let y = dbToY(db, height: usableHeight) + yOffset
            
            let normalizedX = (x / viewportSize.x) * 2.0 - 1.0
            let normalizedY = -(y / viewportSize.y) * 2.0 + 1.0
            
            vertices.append(Vertex(
                position: vector_float2(normalizedX, normalizedY),
                color: vector_float4(1, 1, 1, 0.6)
            ))
        }
        
        if !vertices.isEmpty {
            let vertexBuffer = device.makeBuffer(bytes: &vertices,
                                                length: vertices.count * MemoryLayout<Vertex>.stride,
                                                options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: vertices.count)
        }
    }
    
    private func drawGainReductionMeters(encoder: MTLRenderCommandEncoder, viewportSize: vector_float2,
                                        bandPositions: [(x: Float, y: Float, db: Float, gr: Float)], yOffset: Float) {
        encoder.setRenderPipelineState(fillPipelineState)
        
        let usableHeight = viewportSize.y - 30
        let meterHeight: Float = 20.0
        
        for pos in bandPositions {
            guard pos.gr > 0.1 else { continue }
            
            let normalizedGR = min(pos.gr / 12.0, 1.0) // Max 12dB reduction
            let meterTop = yOffset
            let meterBottom = meterTop + meterHeight
            
            let normalizedX = (pos.x / viewportSize.x) * 2.0 - 1.0
            let normalizedYTop = -(meterTop / viewportSize.y) * 2.0 + 1.0
            let normalizedYBottom = -(meterBottom / viewportSize.y) * 2.0 + 1.0
            
            // Color based on gain reduction amount
            let color: vector_float4
            if normalizedGR < 0.3 {
                color = vector_float4(0.2, 0.9, 0.2, 0.6) // Green
            } else if normalizedGR < 0.6 {
                color = vector_float4(0.9, 0.9, 0.2, 0.6) // Yellow
            } else {
                color = vector_float4(0.9, 0.2, 0.2, 0.6) // Red
            }
            
            let width: Float = 2.0 / viewportSize.x * 5.0
            
            var meterVertices: [Vertex] = [
                Vertex(position: vector_float2(normalizedX - width, normalizedYTop), color: color),
                Vertex(position: vector_float2(normalizedX + width, normalizedYTop), color: color),
                Vertex(position: vector_float2(normalizedX - width, normalizedYBottom), color: color),
                Vertex(position: vector_float2(normalizedX + width, normalizedYBottom), color: color)
            ]
            
            let vertexBuffer = device.makeBuffer(bytes: &meterVertices,
                                                length: meterVertices.count * MemoryLayout<Vertex>.stride,
                                                options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }
    
    // MARK: - Helper Functions
    
    private func catmullRomInterpolate(p0: (x: Float, y: Float, db: Float, gr: Float),
                                      p1: (x: Float, y: Float, db: Float, gr: Float),
                                      p2: (x: Float, y: Float, db: Float, gr: Float),
                                      p3: (x: Float, y: Float, db: Float, gr: Float),
                                      t: Float) -> (x: Float, y: Float) {
        let t2 = t * t
        let t3 = t2 * t
        
        let x = 0.5 * ((2 * p1.x) +
                       (-p0.x + p2.x) * t +
                       (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                       (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
        
        let y = 0.5 * ((2 * p1.y) +
                       (-p0.y + p2.y) * t +
                       (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                       (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
        
        return (x, y)
    }
    
    private func magnitudeToCalibratedDB(_ normalized: Float) -> Float {
        // Convert normalized (0-1) back to dB
        // The analyzer converts: normalized = (dB + 60) / 60
        // So: dB = (normalized * 60) - 60
        let db = (normalized * 60.0) - 60.0
        
        // Only apply reference level offset when NOT auto-scaling
        if autoScale {
            return db  // Show true dB values
        } else {
            return db + referenceLevel  // Offset the display by reference level
        }
    }
    
    private func dbToY(_ db: Float, height: Float) -> Float {
        let dbRange = currentMaxDB - currentMinDB
        let normalizedPosition = (db - currentMinDB) / dbRange
        return height * (1.0 - normalizedPosition)
    }
    
    private func getQ3CurveColor(_ db: Float) -> (r: Float, g: Float, b: Float, a: Float) {
        switch db {
        case ..<(-12):
            return (0.2, 0.9, 0.2, 1.0)
        case -12..<(-3):
            return (0.9, 0.9, 0.2, 1.0)
        case -3..<3:
            return (0.9, 0.5, 0.2, 1.0)
        default:
            return (0.9, 0.2, 0.2, 1.0)
        }
    }
}

// MARK: - Vertex Structure
struct Vertex {
    var position: vector_float2
    var color: vector_float4
}

// MARK: - SwiftUI Metal View
struct Q3MetalView: UIViewRepresentable {
    @ObservedObject var analyzer: UnifiedAudioAnalyser
    @Binding var displayMode: SpectrumDisplayMode
    @Binding var referenceLevel: Float
    @Binding var showGainReduction: Bool
    @Binding var autoScale: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator(analyzer: analyzer)
    }
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        context.coordinator.renderer = Q3MetalRenderer(metalDevice: mtkView.device!, analyzer: analyzer)
        mtkView.delegate = context.coordinator.renderer
        
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.displayMode = displayMode
        context.coordinator.renderer?.referenceLevel = referenceLevel
        context.coordinator.renderer?.showGainReduction = showGainReduction
        context.coordinator.renderer?.autoScale = autoScale
    }
    
    class Coordinator: NSObject {
        var analyzer: UnifiedAudioAnalyser
        var renderer: Q3MetalRenderer?
        
        init(analyzer: UnifiedAudioAnalyser) {
            self.analyzer = analyzer
        }
    }
}

// MARK: - Final SwiftUI View with Controls
struct Q3AnalyzerView: View {
    @ObservedObject var analyzer: UnifiedAudioAnalyser
    @EnvironmentObject var theme: ThemeManager
    
    @State private var displayMode: SpectrumDisplayMode = .stereo
    @State private var referenceLevel: Float = -12.0
    @State private var showGainReduction: Bool = true
    @State private var autoScale: Bool = true
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Metal view
                Q3MetalView(analyzer: analyzer,
                           displayMode: $displayMode,
                           referenceLevel: $referenceLevel,
                           showGainReduction: $showGainReduction,
                           autoScale: $autoScale)
                
                // dB labels (left side)
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 10)
                    
                    ForEach(getDBPositions(height: geometry.size.height - 30), id: \.db) { position in
                        HStack {
                            Text("\(Int(position.db))dB")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(abs(position.db) < 0.1 ? Color(red: 1.0, green: 0.3, blue: 0.3) : .white.opacity(0.5))
                                .frame(width: 35, alignment: .trailing)
                                .offset(y: -4)
                            
                            Spacer()
                        }
                        .frame(height: 0)
                        .offset(y: position.y)
                    }
                    
                    Spacer()
                }
                .frame(maxHeight: .infinity, alignment: .top)
                
                // Frequency labels (bottom)
                VStack {
                    Spacer()
                    
                    HStack(spacing: 0) {
                        Spacer()
                            .frame(width: 30)
                        
                        ZStack(alignment: .top) {
                            ForEach(getFrequencyPositions(width: geometry.size.width - 60), id: \.freq) { position in
                                Text(position.label)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(position.major ? 0.8 : 0.5))
                                    .offset(x: position.x, y: 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Spacer()
                            .frame(width: 30)
                    }
                    .frame(height: 20)
                    .padding(.bottom, 5)
                }
                
                // Controls (top right)
                VStack(spacing: 8) {
                    // Display mode selector
                    Menu {
                        ForEach(SpectrumDisplayMode.allCases, id: \.self) { mode in
                            Button(action: {
                                displayMode = mode
                            }) {
                                HStack {
                                    Text(mode.rawValue)
                                    if displayMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(displayMode.rawValue)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                    }
                    
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    // Auto-scale toggle
                    Button(action: { autoScale.toggle() }) {
                        VStack(spacing: 2) {
                            Image(systemName: autoScale ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                                .font(.system(size: 16))
                                .foregroundColor(autoScale ? .cyan : .white.opacity(0.6))
                            Text("Auto")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    // Reference level controls
                    Button(action: { referenceLevel -= 3 }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(autoScale ? 0.3 : 0.6))
                    }
                    .disabled(autoScale)
                    
                    Text("\(Int(referenceLevel))dB")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(autoScale ? 0.3 : 0.6))
                    
                    Button(action: { referenceLevel += 3 }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(autoScale ? 0.3 : 0.6))
                    }
                    .disabled(autoScale)
                    
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    // Gain reduction toggle
                    Button(action: { showGainReduction.toggle() }) {
                        VStack(spacing: 2) {
                            Image(systemName: showGainReduction ? "chart.bar.fill" : "chart.bar")
                                .font(.system(size: 16))
                                .foregroundColor(showGainReduction ? .green : .white.opacity(0.6))
                            Text("GR")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
    
    private func getDBPositions(height: CGFloat) -> [(db: Float, y: CGFloat)] {
        var positions: [(db: Float, y: CGFloat)] = []
        var db: Float = -60
        
        while db <= 6 {
            let dbRange: Float = 6 - (-60)
            let normalizedPosition = (db - (-60)) / dbRange
            let y = height * CGFloat(1.0 - normalizedPosition)
            
            if Int(db) % 12 == 0 || abs(db) < 0.1 {
                positions.append((db, y))
            }
            
            db += 6
        }
        
        return positions
    }
    
    private func getFrequencyPositions(width: CGFloat) -> [(freq: Float, label: String, major: Bool, x: CGFloat)] {
        let frequencies: [(Float, String, Bool)] = [
            (20, "20", false),
            (50, "50", false),
            (100, "100", true),
            (200, "200", false),
            (500, "500", false),
            (1000, "1k", true),
            (2000, "2k", false),
            (5000, "5k", false),
            (10000, "10k", true),
            (20000, "20k", false)
        ]
        
        return frequencies.map { freq, label, major in
            let minFreq = log10(20.0)
            let maxFreq = log10(20000.0)
            let logFreq = log10(Double(freq))
            let fraction = CGFloat((logFreq - minFreq) / (maxFreq - minFreq))
            let x = width * fraction
            
            return (freq, label, major, x)
        }
    }
}
