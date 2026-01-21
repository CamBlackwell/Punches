import Foundation

enum VisualizationMode: String, CaseIterable, Codable {
    case both = "Both"
    case spectrumOnly = "Spectrum"
    case goniometerOnly = "Goniometer"
    
    var icon: String {
        switch self {
        case .both:
            return "rectangle.split.2x1"
        case .spectrumOnly:
            return "waveform"
        case .goniometerOnly:
            return "scope"
        }
    }
}
