import Foundation
import AVFoundation


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
}
