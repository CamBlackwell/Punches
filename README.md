# silly_speed

An iOS audio player built around real-time signal analysis and playback manipulation.

## Features

### Playback
- Import and play local audio files
- Playlist creation and management
- Loop toggle
- Seek, pause, and queue control

### Pitch and Tempo
- Independent pitch shifting and tempo control, adjusted in real time without reloading the track
- Pitch is measured in cents; tempo is a rate multiplier
- Algorithm selection for pitch processing (Apple AUTimePitch)

### Visualisation
The visualisation panel can be switched between 3 modes:

- **Analyser** — 128-band Q3 spectrum with tap-to-inspect frequency readout
- **Goniometer** — multi-band stereo field display (see below)
- **Art** — album artwork full view

### Multi-Band Goniometer
The goniometer splits the incoming signal into three frequency bands using IIR low-pass filters and renders each as an independent Lissajous plot:

- **Bass (0–300 Hz)** — orange. Bass frequencies in most music are mixed in mono, so this plot typically appears as a narrow vertical cluster near the centre axis.
- **Mids (300 Hz–3 kHz)** — cyan. Melodic and vocal content. Width varies by mix.
- **Highs (3–20 kHz)** — violet. Room, reverb, and transient content. Often the widest of the three.

A phase correlation bar sits below the goniometer. It reads -1 (fully out of phase) to +1 (fully in phase / mono). Values below 0 indicate phase issues that will cause cancellation when summed to mono.

Zoom steps (x1 / x2 / x4 / x8) scale the coordinate space inward, useful for inspecting quiet or low-level material.

### 128-Band Spectrum (Q3)
Displays the frequency spectrum across 128 log-spaced bands from 20 Hz to 20 kHz. Tap and drag to inspect the amplitude and approximate frequency at any point.

## Requirements

- iOS 16 or later
- Xcode 15 or later

## Architecture

The audio graph is built on `AVAudioEngine`. A single `UnifiedAudioAnalyser` installs one tap on the main mixer node and feeds both the spectrum FFT and the goniometer sample buffers. Pitch and tempo processing run through `AVAudioUnitTimePitch` in the engine chain.

The goniometer and spectrum are rendered with Metal (MetalKit). Each view runs its own `MTKViewDelegate` on the Metal render thread; all cross-thread sample handoff is guarded with `os_unfair_lock`.
