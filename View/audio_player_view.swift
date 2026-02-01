import SwiftUI
import Combine

struct AudioPlayerView: View {
    let audioFile: AudioFile
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @State private var volume: Float = 1.0
    @State private var isScrubbing: Bool = false
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    var body: some View {
        ZStack {
            theme.backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 8) {
                visualisationView

                Spacer()

                tempoControl
                pitchControl
                timeSlider
                playbackControls
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(currentFile.title)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                visualisationSelector
            }
        }
        .onChange(of: audioManager.currentlyPlayingID) { _, newID in
            if let newID = newID, newID != currentFile.id {
                sliderValue = 0
            }
        }
    }

     var currentFile: AudioFile {
        audioManager.audioFiles.first(where: {
            $0.id == audioManager.currentlyPlayingID
        }) ?? audioFile
    }

    private var visualisationSelector: some View {
        Menu {
            ForEach(VisualisationMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        audioManager.visualisationMode = mode
                        audioManager.saveVisualisationMode()
                    }
                }) {
                    HStack {
                        Label(mode.rawValue, systemImage: mode.icon)
                        Spacer()
                        if audioManager.visualisationMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: audioManager.visualisationMode.icon)
                    .font(.subheadline)
                    .tint(theme.textColor)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var visualisationView: some View {
        switch audioManager.visualisationMode {
        case .both:
            VStack(spacing: 20) {
                SpectrumView(analyzer: audioManager.audioAnalyzer)
                    .frame(height: 140)
                    .transition(.move(edge: .top).combined(with: .opacity))

                GoniometerView(analyzer: audioManager.audioAnalyzer)
                    .frame(height: 150)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        case .spectrumOnly:
            SpectrumView(analyzer: audioManager.audioAnalyzer)
                .frame(maxHeight: .infinity)
                .transition(.scale.combined(with: .opacity))

        case .goniometerOnly:
            GoniometerView(analyzer: audioManager.audioAnalyzer)
                .frame(maxHeight: .infinity)
                .transition(.scale.combined(with: .opacity))
        
        case .q3Spectrum:
            Q3AnalyzerView(analyzer: audioManager.audioAnalyzer)
                .frame(maxHeight: .infinity)
                .transition(.scale.combined(with: .opacity))

        case .albumArt:
            if let name = currentFile.artworkImageName,
               let artwork = audioManager.artworkService.loadArtworkImage(name) {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: .infinity)
                    .cornerRadius(12)
                    .transition(.scale.combined(with: .opacity))
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    Text("No artwork")
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .frame(maxHeight: .infinity)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var isThisFilePlaying: Bool {
        audioManager.isPlaying && audioManager.currentlyPlayingID == currentFile.id
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var algorithmSelector: some View {
        let implementedAlgorithms = PitchAlgorithm.allCases.filter { $0.isImplemented }

        return Menu {
            ForEach(implementedAlgorithms, id: \.self) { algorithm in
                Button(action: {
                    audioManager.changeAlgorithm(to: algorithm)
                }) {
                    HStack {
                        Text(algorithm.rawValue)
                        Spacer()
                        if audioManager.selectedAlgorithm == algorithm {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text("\(audioManager.selectedAlgorithm.rawValue)")
                    .font(.subheadline)
                    .tint(theme.textColor)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .tint(theme.textColor)
            }
            .padding()
        }
    }

    private var timeSlider: some View {
        VStack(spacing: 8) {
            Slider(
                value: $sliderValue,
                in: 0...max(audioManager.duration, 0.01),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        audioManager.seek(to: sliderValue)
                    }
                }
            )
            .tint(theme.accentColor)
            .disabled(audioManager.currentlyPlayingID == nil)
            .onChange(of: audioManager.currentTime) { _, newTime in
                if !isDragging {
                    sliderValue = newTime
                }
            }
            .onAppear { sliderValue = audioManager.currentTime }

            HStack {
                Text(formatTime(isDragging ? sliderValue : audioManager.currentTime))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text(formatTime(audioManager.duration))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .padding(.horizontal)
    }

    private var playbackControls: some View {
        ZStack {
            HStack(spacing: 40) {
                Button(action: { audioManager.skipPreviousSong() }) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    if audioManager.audioFiles.isEmpty {
                        return
                    }

                    if audioManager.currentlyPlayingID == currentFile.id {
                        audioManager.togglePlayPause()
                    } else {
                        audioManager.play(audioFile: currentFile)
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 70, height: 70)

                        Image(systemName: isThisFilePlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(theme.playButtonColor)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { audioManager.skipNextSong() }) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(audioManager.audioFiles.count < 2)
            }

            HStack {
                Spacer()
                Button(action: {
                    audioManager.isLooping.toggle()
                }) {
                    Image(systemName: audioManager.isLooping ? "repeat.1" : "repeat")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(audioManager.isLooping ? theme.accentColor : theme.secondaryTextColor)
                        .padding(10)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var tempoControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Speed")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("\(audioManager.tempo, specifier: "%.2f")x")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textColor)
                Spacer()
                resetTempoButton
            }

            Slider(value: Binding(
                get: { audioManager.tempo },
                set: { audioManager.setTempo($0) }
            ), in: 0.1...1.9)
            .tint(theme.accentColor)

            HStack {
                Text("0.1x")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("1.0x")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("2.0x")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .padding(.horizontal)
    }

    private var pitchControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Pitch")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("\(audioManager.pitch / 100, specifier: "%.2f") semitones")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textColor)
                Spacer()
                resetPitchButton
            }

            Slider(value: Binding(
                get: { audioManager.pitch },
                set: { audioManager.setPitch($0) }
            ), in: -2400...2400)
            .tint(theme.accentColor)

            HStack {
                Text("-2 oct")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("Normal")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("+2 oct")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .padding(.horizontal)
    }

    private var resetTempoButton: some View {
        Button(action: {
            audioManager.setTempo(1.0)
        }) {
            Image(systemName: "arrow.counterclockwise")
                .font(.subheadline)
                .foregroundStyle(theme.accentColor)
        }
        .padding(.horizontal)
    }

    private var resetPitchButton: some View {
        Button(action: {
            audioManager.setPitch(0.0)
        }) {
            Image(systemName: "arrow.counterclockwise")
                .font(.subheadline)
                .foregroundStyle(theme.accentColor)
        }
        .padding(.horizontal)
    }
}
