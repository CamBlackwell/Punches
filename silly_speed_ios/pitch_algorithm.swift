import Foundation

enum PitchAlgorithm: String, CaseIterable, Codable {
    case apple = "Apple (Default)"
    case rubberBand = "Rubber Band (Best quality for extreme changes)"
    case soundTouch = "SoundTouch (Balanced quality and performance)"
    case signalSmith = "SignalSmith (Modern)"
    
    var isImplemented: Bool {
        switch self {
        case .apple, .soundTouch:
            return true
        case .rubberBand, .signalSmith:
            return false
        }
    }
}
