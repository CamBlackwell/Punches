import Foundation
import AVFoundation

/// Debug metrics for the playback engine (DEBUG builds)
public struct EngineDebugMetrics {
    public let starveCount: Int
    public let maxScheduledAhead: Int
    public let avgScheduleMs: Double

    public init(starveCount: Int, maxScheduledAhead: Int, avgScheduleMs: Double) {
        self.starveCount = starveCount
        self.maxScheduledAhead = maxScheduledAhead
        self.avgScheduleMs = avgScheduleMs
    }
}

protocol AudioEngineProtocol {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
   
    func getAudioEngine() -> AVAudioEngine?
    func load(audioFile: AudioFile)
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval)
    func setVolume(_ volume: Float)
    func setTempo (_ tempo: Float)
    func setPitch (_ pitch: Float)

    /// Engine debug metrics (available in DEBUG builds; values may be zeroed in Release)
    var debugMetrics: EngineDebugMetrics { get }
}
