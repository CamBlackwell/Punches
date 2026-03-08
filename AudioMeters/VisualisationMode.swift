import Foundation

enum VisualisationMode: String, Codable, CaseIterable {
  case both
  case spectrumOnly
  case goniometerOnly
  case albumArt
  case q3Spectrum

  var icon: String {
    switch self {
    case .both: return "square.grid.2x2"
    case .spectrumOnly: return "waveform"
    case .goniometerOnly: return "circle.grid.cross"
    case .albumArt: return "photo"
    case .q3Spectrum: return "chart.bar.fill"
    }
  }

  /// Human-readable label shown in the view selector.
  var label: String {
    switch self {
    case .both: return "Both"
    case .spectrumOnly: return "Spectrum"
    case .goniometerOnly: return "Goniometer"
    case .albumArt: return "Art"
    case .q3Spectrum: return "Analyser"
    }
  }
}
