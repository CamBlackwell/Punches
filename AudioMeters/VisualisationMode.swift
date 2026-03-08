import Foundation

enum VisualisationMode: String, Codable, CaseIterable {
  //case both
  //case spectrumOnly
  case Goniometer
  case Artwork
  case Spectrum

  var icon: String {
    switch self {
    //case .both: return "square.grid.2x2"
    //case .spectrumOnly: return "waveform"
    case .Artwork: return "photo"
    case .Goniometer: return "circle"
    case .Spectrum: return "chart.bar.fill"
    }
  }

  /// Human-readable label shown in the view selector.
  var label: String {
    switch self {
    //case .both: return "Both"
    //case .spectrumOnly: return "Spectrum"
    case .Artwork: return "Art"
    case .Goniometer: return "Goniometer"
    case .Spectrum: return "Spectrum"
    }
  }
}
