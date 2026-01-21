import Foundation

enum VisualisationMode: String, Codable, CaseIterable {
    case both
    case spectrumOnly
    case goniometerOnly
    case albumArt

    var icon: String {
        switch self {
        case .both: return "square.grid.2x2"
        case .spectrumOnly: return "waveform"
        case .goniometerOnly: return "circle.grid.cross"
        case .albumArt: return "photo"
        }
    }
}
