import Foundation
import SwiftUI

// MARK: - Frequency Mapping Utilities (Shared between Analyzer and Renderer)

/// Central source of truth for frequency mapping
/// Use these functions in BOTH UnifiedAudioAnalyser and Q3MetalRenderer
struct FrequencyMapper {
    static let minFrequency: Float = 20.0
    static let maxFrequency: Float = 20000.0
    static let minFreqLog = log10(minFrequency)
    static let maxFreqLog = log10(maxFrequency)
    static let logRange = maxFreqLog - minFreqLog
    
    /// Convert band index to center frequency (logarithmic)
    static func bandIndexToFrequency(index: Int, totalBands: Int) -> Float {
        let fraction = Float(index) / Float(totalBands - 1)
        let logFreq = minFreqLog + fraction * logRange
        return Float(pow(10.0, logFreq))
    }
    
    /// Convert frequency to X position in pixels (logarithmic scale)
    static func frequencyToX(_ frequency: Float, width: Float) -> Float {
        let logFreq = log10(frequency)
        let fraction = (logFreq - minFreqLog) / logRange
        return Float(fraction) * width
    }
    
    /// Convert X position to frequency
    static func xToFrequency(_ x: Float, width: Float) -> Float {
        let fraction = Double(x / width)
        let logFreq = minFreqLog + Float(fraction) * logRange
        return Float(pow(10.0, logFreq))
    }
    
    /// Get frequency boundaries for a band (geometric mean with neighbors)
    static func bandFrequencyRange(index: Int, totalBands: Int) -> (low: Float, center: Float, high: Float) {
        let centerFreq = bandIndexToFrequency(index: index, totalBands: totalBands)
        
        let prevIndex = max(index - 1, 0)
        let nextIndex = min(index + 1, totalBands - 1)
        
        let prevFreq = bandIndexToFrequency(index: prevIndex, totalBands: totalBands)
        let nextFreq = bandIndexToFrequency(index: nextIndex, totalBands: totalBands)
        
        // Geometric mean for boundaries
        let lowFreq = index == 0 ? minFrequency : sqrt(centerFreq * prevFreq)
        let highFreq = index == totalBands - 1 ? maxFrequency : sqrt(centerFreq * nextFreq)
        
        return (lowFreq, centerFreq, highFreq)
    }
}

// MARK: - Alignment Tests

class FrequencyAlignmentTests {
    
    /// Test that band frequencies align with grid frequencies
    static func testBandToGridAlignment(bandCount: Int = 64) -> [(bandIndex: Int, bandFreq: Float, nearestGridFreq: Float, error: Float)] {
        let gridFrequencies: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        var results: [(Int, Float, Float, Float)] = []
        
        for i in 0..<bandCount {
            let bandFreq = FrequencyMapper.bandIndexToFrequency(index: i, totalBands: bandCount)
            
            // Find nearest grid frequency
            var nearestGridFreq: Float = gridFrequencies[0]
            var minError = abs(log10(bandFreq) - log10(nearestGridFreq))
            
            for gridFreq in gridFrequencies {
                let error = abs(log10(bandFreq) - log10(gridFreq))
                if error < minError {
                    minError = error
                    nearestGridFreq = gridFreq
                }
            }
            
            // If band is very close to a grid frequency, record it
            if minError < 0.05 { // Within ~10% in log scale
                results.append((i, bandFreq, nearestGridFreq, Float(minError)))
            }
        }
        
        return results
    }
    
    /// Test that X position calculated from frequency is consistent
    static func testFrequencyToXConsistency(width: Float = 1000) -> Bool {
        let testFrequencies: [Float] = [20, 100, 1000, 10000, 20000]
        
        for freq in testFrequencies {
            let x = FrequencyMapper.frequencyToX(freq, width: width)
            let reconverted = FrequencyMapper.xToFrequency(x, width: width)
            let error = abs(freq - reconverted) / freq
            
            if error > 0.001 { // More than 0.1% error
                print("❌ Frequency \(freq) Hz: X=\(x) -> \(reconverted) Hz (error: \(error * 100)%)")
                return false
            } else {
                print("✅ Frequency \(freq) Hz: X=\(x) -> \(reconverted) Hz")
            }
        }
        return true
    }
    
    /// Test FFT bin to frequency calculation
    static func testFFTBinMapping(sampleRate: Float = 44100, fftSize: Int = 8192) {
        let binResolution = sampleRate / Float(fftSize)
        let testFrequencies: [Float] = [20, 100, 1000, 10000, 20000]
        
        print("\n=== FFT Bin Mapping Test ===")
        print("Sample Rate: \(sampleRate) Hz")
        print("FFT Size: \(fftSize)")
        print("Bin Resolution: \(binResolution) Hz/bin")
        print("")
        
        for freq in testFrequencies {
            let exactBin = freq / binResolution
            let lowBin = Int(floor(exactBin))
            let highBin = Int(ceil(exactBin))
            let fraction = exactBin - Float(lowBin)
            
            print("Frequency: \(freq) Hz")
            print("  Exact Bin: \(exactBin)")
            print("  Low Bin: \(lowBin) (\(Float(lowBin) * binResolution) Hz)")
            print("  High Bin: \(highBin) (\(Float(highBin) * binResolution) Hz)")
            print("  Fraction: \(fraction)")
            print("")
        }
    }
    
    /// Visual test: Generate positions for all bands and grid lines
    static func generateVisualTestData(bandCount: Int = 64, width: Float = 1000) -> (bands: [(index: Int, freq: Float, x: Float)], grid: [(freq: Float, x: Float)]) {
        var bandData: [(Int, Float, Float)] = []
        var gridData: [(Float, Float)] = []
        
        // Band positions
        for i in 0..<bandCount {
            let freq = FrequencyMapper.bandIndexToFrequency(index: i, totalBands: bandCount)
            let x = FrequencyMapper.frequencyToX(freq, width: width)
            bandData.append((i, freq, x))
        }
        
        // Grid positions
        let gridFrequencies: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        for freq in gridFrequencies {
            let x = FrequencyMapper.frequencyToX(freq, width: width)
            gridData.append((freq, x))
        }
        
        return (bandData, gridData)
    }
    
    /// Run all tests
    static func runAllTests() {
        print("🧪 Running Frequency Alignment Tests\n")
        print("=" * 60)
        
        // Test 1: Frequency to X consistency
        print("\n📍 Test 1: Frequency ↔ X Position Consistency")
        print("-" * 60)
        let test1Pass = testFrequencyToXConsistency(width: 1000)
        print(test1Pass ? "✅ PASSED" : "❌ FAILED")
        
        // Test 2: Band to Grid alignment
        print("\n📍 Test 2: Band-to-Grid Alignment (64 bands)")
        print("-" * 60)
        let alignmentResults = testBandToGridAlignment(bandCount: 64)
        print("Bands near grid frequencies:")
        for result in alignmentResults {
            print("  Band \(result.bandIndex): \(String(format: "%.1f", result.bandFreq)) Hz " +
                  "≈ \(String(format: "%.0f", result.nearestGridFreq)) Hz " +
                  "(error: \(String(format: "%.4f", result.error)))")
        }
        
        // Test 3: FFT bin mapping
        print("\n📍 Test 3: FFT Bin Mapping")
        print("-" * 60)
        testFFTBinMapping(sampleRate: 44100, fftSize: 8192)
        
        // Test 4: Visual alignment data
        print("\n📍 Test 4: Visual Alignment Check")
        print("-" * 60)
        let (bands, grid) = generateVisualTestData(bandCount: 64, width: 1000)
        print("Grid line positions:")
        for (freq, x) in grid {
            print("  \(String(format: "%5.0f", freq)) Hz -> X: \(String(format: "%.2f", x)) px")
        }
        print("\nSample band positions:")
        for i in [0, 15, 31, 47, 63] {
            let band = bands[i]
            print("  Band \(String(format: "%2d", band.index)): \(String(format: "%7.1f", band.freq)) Hz -> X: \(String(format: "%.2f", band.x)) px")
        }
        
        print("\n" + "=" * 60)
        print("✅ All tests completed!")
    }
}

// MARK: - Visual Debug View

struct FrequencyAlignmentDebugView: View {
    let bandCount: Int = 64
    let width: CGFloat = 800
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Frequency Alignment Visualization")
                .font(.title)
                .padding()
            
            GeometryReader { geometry in
                ZStack {
                    // Background
                    Rectangle()
                        .fill(Color.black)
                    
                    // Grid lines (red)
                    ForEach(gridPositions, id: \.freq) { position in
                        Path { path in
                            let x = position.x
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(Color.red, lineWidth: 2)
                        
                        Text("\(Int(position.freq))Hz")
                            .font(.caption)
                            .foregroundColor(.red)
                            .position(x: position.x, y: 20)
                    }
                    
                    // Band positions (green)
                    ForEach(bandPositions, id: \.index) { position in
                        Path { path in
                            let x = position.x
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    }
                    
                    // Highlight bands near grid frequencies
                    ForEach(highlightedBands, id: \.index) { position in
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 10, height: 10)
                            .position(x: position.x, y: geometry.size.height / 2)
                    }
                }
            }
            .frame(height: 300)
            .padding()
            
            // Legend
            HStack(spacing: 30) {
                HStack {
                    Rectangle().fill(Color.red).frame(width: 20, height: 3)
                    Text("Grid Lines")
                }
                HStack {
                    Rectangle().fill(Color.green).frame(width: 20, height: 3)
                    Text("Band Centers")
                }
                HStack {
                    Circle().fill(Color.yellow).frame(width: 10, height: 10)
                    Text("Aligned Bands")
                }
            }
            .font(.caption)
            .padding()
            
            // Test Results
            Button("Run Alignment Tests") {
                FrequencyAlignmentTests.runAllTests()
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
    }
    
    var bandPositions: [(index: Int, freq: Float, x: CGFloat)] {
        let (bands, _) = FrequencyAlignmentTests.generateVisualTestData(
            bandCount: bandCount,
            width: Float(width)
        )
        return bands.map { (index: $0.index, freq: $0.freq, x: CGFloat($0.x)) }
    }
    
    var gridPositions: [(freq: Float, x: CGFloat)] {
        let (_, grid) = FrequencyAlignmentTests.generateVisualTestData(
            bandCount: bandCount,
            width: Float(width)
        )
        return grid.map { (freq: $0.freq, x: CGFloat($0.x)) }
    }
    
    var highlightedBands: [(index: Int, freq: Float, x: CGFloat)] {
        let alignments = FrequencyAlignmentTests.testBandToGridAlignment(bandCount: bandCount)
        let (bands, _) = FrequencyAlignmentTests.generateVisualTestData(
            bandCount: bandCount,
            width: Float(width)
        )
        
        return alignments.map { alignment in
            let band = bands.first { $0.index == alignment.bandIndex }!
            return (index: band.index, freq: band.freq, x: CGFloat(band.x))
        }
    }
}

// Helper for string multiplication
extension String {
    static func * (left: String, right: Int) -> String {
        String(repeating: left, count: right)
    }
}
