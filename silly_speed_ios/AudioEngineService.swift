import Foundation
import AVFoundation

final class AudioEngineService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    func initialiseEngine() {
        switch manager.selectedAlgorithm {
        case .apple:
            manager.currentEngine = AppleAudioEngine()
        case .rubberBand:
            manager.currentEngine = nil
        case .soundTouch:
            manager.currentEngine = nil
        case .signalSmith:
            manager.currentEngine = nil
        }

    }

    func loadSelectedAlgorithm() {
        if let saved = UserDefaults.standard.string(forKey: manager.algorithmKey),
           let algorithm = PitchAlgorithm(rawValue: saved),
           algorithm.isImplemented {
            manager.selectedAlgorithm = algorithm
        }
    }

    func saveSelectedAlgorithm() {
        UserDefaults.standard.set(manager.selectedAlgorithm.rawValue, forKey: manager.algorithmKey)
    }

    func changeAlgorithm(to algorithm: PitchAlgorithm) {
        guard algorithm.isImplemented else {
            print("Algorithm \(algorithm.rawValue) not implemented yet")
            return
        }

        let wasPlaying = manager.isPlaying
        let currentAudioFile = manager.audioFiles.first { $0.id == manager.currentlyPlayingID }
        let savedTime = manager.currentTime

        if let oldEngine = manager.currentEngine?.getAudioEngine() {
            manager.audioAnalyzer.detach(from: oldEngine)
        }

        manager.stop()

        manager.selectedAlgorithm = algorithm
        saveSelectedAlgorithm()
        initialiseEngine()

        if let audioFile = currentAudioFile {
            manager.currentEngine?.load(audioFile: audioFile)
            manager.currentEngine?.setTempo(manager.tempo)
            manager.currentEngine?.setPitch(manager.pitch)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.manager.currentEngine?.seek(to: savedTime)
                if wasPlaying {
                    self.manager.play(audioFile: audioFile)
                }
            }
        }
    }
}
