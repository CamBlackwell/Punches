# 04 — Audio Pipeline

> Everything from the `AVAudioEngine` graph down to individual `AVAudioPCMBuffer` scheduling. This is the doc for anyone changing playback, seeking, buffering or pitch/tempo.
> Companion: [05-signal-analysis.md](05-signal-analysis.md) (what happens to the tapped samples).

---

## 1. The engine graph

Built in `AppleAudioEngine.setupAudioEngine()` (`AudioEngines/AppleAudioEngine.swift:76-87`):

```
AVAudioPlayerNode ──► AVAudioUnitTimePitch ──► mainMixerNode ──► output
  (file playback)      (rate + pitch)          (tap installed here,
                                              bufferSize = hopSize)
```

`timePitch → mainMixerNode` is seeded with `format: nil`, so the mixer converts to whatever the hardware is doing. **`playerNode → timePitch` is not left at `nil`**: a node's output format is fixed by its connection and `AVAudioPlayerNode` inserts no sample-rate converter, so a `nil` connection made before any file exists pins the player to the session rate and plays every mismatched file at the wrong speed *and* pitch.

`reconfigureGraphIfNeeded` (`:118`) therefore reconnects **both** edges in the file's `processingFormat` on every load, letting the mixer do the conversion. Both edges are required, and the second one is the subtle half: **`AVAudioUnitTimePitch` pins its own output rate at connect time and does not follow its input.** Reconnecting only the player edge leaves the unit rendering at its original rate, so the mismatch is relocated one node downstream and the detune is unchanged — the player's format is the one that updates, which is exactly why guarding on it looks correct and is not. The guard reads `timePitch.inputFormat(forBus: 0)` instead, the junction between the two nodes and the format that actually stuck. See [E17](14-known-issues.md).

Whichever way the edges above are connected, `mainMixerNode`'s **output** format stays at the hardware rate — which matters, because that is the bus the analyser taps.

The mixer output format — and therefore the tap format — is only valid *after* the engine has been prepared and started.

Nodes (`AppleAudioEngine.swift:6-8`):

| Node | Type | Notes |
|---|---|---|
| `audioEngine` | `AVAudioEngine` | exposed to the analyser via `getAudioEngine()` |
| `playerNode` | `AVAudioPlayerNode` | buffers are scheduled manually, **not** with `scheduleFile` |
| `timePitch` | `AVAudioUnitTimePitch` | the only pitch/tempo node; `rate` and `pitch` are set directly |

> **Design decision:** `scheduleFile` would be simpler, but manual buffer scheduling is what makes the starvation metrics, the `seekOffset` model and the `isUserStopped` flag possible. Do not "simplify" this to `scheduleFile` — `AudioPlaybackService.seek` and the DEBUG HUD both depend on the manual model.

---

## 2. The three-buffer setup sequence

`AppleAudioEngine.init` (`:57-67`) and `setupAudioEngine` do redundant work on purpose:

```swift
// setupAudioEngine() :76-87  — attach, connect, prepare, start
// init() :61-66              — prepare, start AGAIN (failure tolerated)
```

`reconfigureGraphIfNeeded` (`:118-150`) runs from `load()` (`:259`) **before anything is scheduled**: it compares the file's rate and channel count against `timePitch.inputFormat(forBus: 0)`, and only on a difference stops the engine, disconnects the player *and* the time-pitch unit, and reconnects both edges in `file.processingFormat`. Both disconnects are required — reconnecting a still-connected bus raises. Same-format track changes skip it entirely, so they cost one comparison; a genuine rate change happens only across a track change, which has already stopped the node, so the reconfig rides on an existing boundary rather than cutting into playback.

`warmupTimePitchIfNeeded` (`:168-…`) then runs once per engine — not from `init` — scheduling a 512-frame silent buffer through the player node, playing, and immediately stopping. This forces `AVAudioUnitTimePitch` to run its first render pass so the first real track does not pay a one-time latency spike. It reads the **player's** format, not the mixer's: a warm-up buffer in the mixer's format would pin the node to the hardware rate and reintroduce [E17](14-known-issues.md) by a second route. The engine is running before any audio exists, which is why `isPlaying` is false but the graph is live.

---

## 3. Buffer scheduling — the core loop

### Tunables

| Constant | Value | Line |
|---|---|---|
| `buffersAhead` | `5` | `AppleAudioEngine.swift:18` |
| `bufferDuration` | `0.25` s | `:19` |
| `bufferFrameCapacity` | `max(sampleRate * 0.25, 1024)` frames, computed once per `load` | `:152-159` |

So the engine is kept fed with **1.25 seconds** of audio (5 × 0.25 s), recomputed on every buffer completion.

### `scheduleBuffersIfNeeded()` (`:183-257`)

```
while scheduledBuffersCount < 5 && currentFramePosition < file.length:
    framesToRead  = min(file.length - currentFramePosition, bufferFrameCapacity)
    buffer        = AVAudioPCMBuffer(pcmFormat: file.processingFormat, ...)
    file.framePosition = currentFramePosition      ← re-seek per buffer
    try file.read(into: buffer, frameCount: framesToRead)
    currentFramePosition += framesToRead
    atEnd = currentFramePosition >= file.length
    scheduledBuffersCount += 1
    playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { ... }
    if atEnd: break
```

Three details matter:

1. **`file.framePosition` is re-assigned per buffer** (`:116`). `AVAudioFile` maintains its own read cursor, and the completion callback may re-enter the scheduler from a different buffer than expected. Re-seeking each time makes the loop order-independent.
2. **`completionCallbackType: .dataPlayedBack`** (`:140`), not the default `.dataConsumed`. `.dataPlayedBack` fires after the samples have been rendered, so decrementing there means `scheduledBuffersCount` reflects *actual headroom*, not merely queued data. This is the difference between a correct and a drifting buffer model.
3. **`scheduleBuffer(_:at:options:)` with no `at:`** — everything is immediate.

### The completion handler (`:141-161`)

Runs on the render thread; the body immediately re-dispatches to `audioQueue`:

```swift
playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
    self.audioQueue.async {
        if self.isUserStopped { return }               // ← early-out for stop()
        self.scheduledBuffersCount -= 1
        #if DEBUG
        if self.playerNode.isPlaying && !self.isUserStopped && !atEnd
           && self.scheduledBuffersCount == 0 {
            self.debug_starveCount &+= 1               // ← dropped to zero headroom mid-play
        }
        #endif
        if atEnd && self.scheduledBuffersCount == 0 {
            self.isFileFinished = true
            DispatchQueue.main.async { self.onPlaybackFinished?() }
        } else {
            self.scheduleBuffersIfNeeded()             // ← the recursion that sustains playback
        }
    }
}
```

Three things to understand here:

- **The `isUserStopped` early-out at `:144` prevents the refilling recursion from resurrecting a stopped engine.** Without it, a completion callback already in flight after `stop()` would call `scheduleBuffersIfNeeded` and queue audio that never plays.
- **Starvation definition** (`:147-150`) is precise: buffers reached zero *while the player node was actually playing* and *not at end of file*. It counts real underruns, not the normal moment between the last buffer of a file and end-of-stream handling.
- **End-of-file detection requires `atEnd && scheduledBuffersCount == 0`**, i.e. the final buffer has actually been *rendered*, not merely queued. `onPlaybackFinished` then hops to main before firing, so the skip-next chain runs on the main actor.

### Recursion depth

Each completion calls `scheduleBuffersIfNeeded` again. Because it is dispatched (not called directly), the stack never grows. This is a self-sustaining loop broken only by `isUserStopped`, `isFileFinished`, or `load`/`seek`/`stop` resetting the counters.

---

## 4. Playback state machine

Five pieces of mutable state drive everything (`:11-16`):

| Field | Reset by | Meaning |
|---|---|---|
| `seekOffset` | `load` (`:179`), `stop` (`:229`), recomputed in `play` (`:209-213`) and `seek` (`:253`) | time in seconds before the first scheduled sample |
| `currentFramePosition` | `load` (`:180`), `stop` (`:230`), `seek` (`:252`) | file frame index of the next sample to read |
| `scheduledBuffersCount` | `load`, `stop`, `seek` (and `±1` in the completion) | buffers queued in the player node |
| `isFileFinished` | `load`, `stop`, `seek`; set `true` at `:153` | all frames read and rendered |
| `isUserStopped` | `load` (`:184`), `seek` (`:244`); set `true` in `stop` (`:227`) | suppresses the refill recursion |

### `load(audioFile:)` (`:175-189`)

Async on `audioQueue`. Opens `AVAudioFile(forReading:)` and resets all five fields. **Does not touch the player node** — the caller decides whether to `play()`.

> **Gotcha:** `load` is fire-and-forget. `AudioPlaybackService.play` calls `engine.stop()`, then `engine.load()`, then `engine.play()` in immediate succession (`:43-54`), all of which enqueue onto the same serial `audioQueue`, so ordering holds. But any *new* caller that awaits nothing and calls `play()` from a different queue will race.

### `play()` (`:191-219`)

1. If the engine is not running, `prepare()` + `start()` (`:195-203`).
2. If the player node is not playing:
   - clear `isUserStopped`
   - if nothing is scheduled and the file is not finished, recompute `seekOffset` from `currentFramePosition` (or zero it if at frame 0) and call `scheduleBuffersIfNeeded()`
   - `playerNode.play()`

Calling `play()` when already playing is a no-op, which is what makes `togglePlayPause` and the interruption-resume path safe to call repeatedly.

### `pause()` (`:221-223`)

`playerNode.pause()` directly, **not** on `audioQueue`. Scheduled buffers are retained, so resume continues from the same point. `isUserStopped` is untouched, so the refill recursion is still armed — but it will find `scheduledBuffersCount == 5` and do nothing until a completion fires.

### `stop()` (`:225-235`)

Async: sets `isUserStopped = true` **first**, then `playerNode.stop()`, then zeroes everything. The ordering is the important part — the flag must be set before the node stops, so that in-flight completions bail at `:144` instead of refilling.

### `seek(to:)` (`:237-270`)

```
wasPlaying = playerNode.isPlaying
playerNode.stop(); isUserStopped = false
scheduledBuffersCount = 0; isFileFinished = false
clampedTime    = max(0, min(time, duration))
currentFramePosition = clamp(clampedTime * sampleRate, 0, file.length)
seekOffset     = currentFramePosition / sampleRate
scheduleBuffersIfNeeded()
if wasPlaying { ensure engine running; playerNode.play() }
```

This is a **hard stop-and-reschedule**, not an in-place reposition. It is therefore *not* seamless — expect a click on seek.

> **`duration` now uses `processingFormat` too** (`:46`: `file.length / file.processingFormat.sampleRate`), matching `seek` (`:330`) and `currentTime` (`:42`). It used to divide by `fileFormat.sampleRate` instead — the on-disk stream rate, which is lower whenever the decoder up-samples, HE-AAC being the common case (encodes at 22.05/24 kHz, decodes to 44.1/48 kHz). That reported roughly double the real duration and disagreed with the seek clock on exactly the files most likely to have it; see [E17](14-known-issues.md). `AudioPlaybackService` still keeps its own `manager.duration` from `AudioFile.audioDuration` (imported at read time), and the timer compares `currentTime >= duration` (`:134`) — so there are still two sources of truth for duration, which [E15](14-known-issues.md) owns.

---

## 5. Time reporting

```swift
// AppleAudioEngine.swift:37-44
var currentTime: TimeInterval {
    guard let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
        return seekOffset
    }
    let calculatedTime = seekOffset + (Double(playerTime.sampleTime) / playerTime.sampleRate)
    return min(calculatedTime, duration)
}
```

`playerTime.sampleTime` is relative to the last `play()`, so the absolute position is `seekOffset + elapsed`. Falls back to `seekOffset` when no render has happened. Clamped to `duration` so a slow buffer drain cannot report a time past the end.

`AudioPlaybackService.startTimer()` (`Services/AudioPlaybackService.swift:117-138`) polls this at **0.2 s** and:

- skips entirely while `manager.isSeeking` (`:122`)
- writes `manager.currentTime` every tick (`:127`)
- refreshes `MPNowPlayingInfo` only when the integer second changes (`:129-132`)
- auto-advances when `currentTime >= duration && duration > 0` (`:134-136`)

`isSeeking` is a 0.15 s debounce flag set in `seek(to:)` (`AudioPlaybackService.swift:94, 98-100`) that stops the timer fighting the user's drag.

> **There are two independent end-of-track detectors**: this timer check and the engine's `onPlaybackFinished` → `skipNextSong()` chain. Both are live. Whichever fires first wins, and the second becomes a redundant `skipNextSong()`. If you change skip semantics, check both.

---

## 6. Pitch and tempo

```swift
// AppleAudioEngine.swift:367-375
func setTempo(_ tempo: Float) { audioQueue.async { self.timePitch.rate  = tempo } }
func setPitch(_ pitch: Float) { audioQueue.async { self.timePitch.pitch = pitch } }
```

Clamps are applied by the caller, not the engine (`AudioPlaybackService.swift:107-115`):

| Control | Clamp | Unit | Re-applied on every track change? |
|---|---|---|---|
| Tempo | `0.1 … 4.0` | `AVAudioUnitTimePitch.rate` multiplier | yes — `play()` re-applies `manager.tempo` (`AudioPlaybackService.swift:51`) |
| Pitch | `-2400 … 2400` | cents | yes — `play()` re-applies `manager.pitch` (`:52`) |

> **Gotcha — tempo is unreachable in the UI.** `AudioPlaybackService` supports `0.1…4.0` and the pitch slider is live, but the tempo slider is **commented out of the player layout** (`View/audio_player_view.swift:22`, with the view itself at `:230-266`). There is no way to change playback speed in the shipped app. See [14-known-issues.md](14-known-issues.md#d2-tempo-control-is-commented-out).

`setVolume` (`:272-274`) sets `playerNode.volume` and is **not exposed anywhere** in the UI — `AudioPlayerView` has a `volume: Float = 1.0` state that is never read (`View/audio_player_view.swift:8`).

Neither `tempo` nor `pitch` is persisted. See [12-persistence-and-keys.md](12-persistence-and-keys.md#6-what-survives-a-relaunch).

---

## 7. Queue, skip and loop

All in `Services/AudioPlaybackService.swift`.

### Queue construction (`play`, `:12-19`)

```swift
if let context = context {
    manager.playbackQueue = context
} else if manager.playbackQueue.isEmpty
          || !manager.playbackQueue.contains(where: { $0.id == audioFile.id }) {
    manager.playbackQueue = manager.sortedAudioFiles
}
```

Passing an explicit `context` (the visible list) makes the queue follow the user's browsing context. Without one, the queue falls back to the whole library — but only if the current queue does not already contain the track. See [08-playlists-and-library.md](08-playlists-and-library.md#6-reordering).

### `skipNextSong()` (`:178-203`)

```
stopTimer()
if playbackQueue is empty → stop()
find currentIndex in queue
  nextIndex = currentIndex + 1
  if nextIndex < count            → play(queue[nextIndex], context: queue)
  else if isLooping               → play(queue.first,  context: queue)
  else                            → stop()
if current track is NOT in queue  → play(queue.first,  context: queue)
```

`isLooping` is the *only* loop mode: a single-item playlist with looping on will spin that item forever. There is no "loop one" vs "loop all" distinction, and `stop()` at the end of a non-looping queue **deactivates the `AVAudioSession`** (`:70-74`), so a subsequent play has to re-activate it (`:28-35`).

### `skipPreviousSong()` (`:145-161`)

```swift
if manager.currentTime > 3.0 { restartCurrentSong(); return }   // the "3-second rule"
```

`restartCurrentSong()` (`:163-176`) seeks to 0, ensures the engine is playing, restarts the timer if it was nil, and refreshes now-playing. Otherwise it plays `queue[currentIndex - 1]`, or restarts the current song if `currentIndex == 0`.

This 3-second rule is the single most user-visible piece of playback logic and is easy to break when refactoring skip behaviour.

### `reorderSelectedSongs` (`:205-246`)

The group-move algorithm for multi-select drag:

```swift
selectedIndices  = indices of selectedIDs, ascending
selectedSongs    = currentSongs[selectedIndices]
songs            = currentSongs with selectedIndices removed (reverse order)
adjustedDestination = destination - selectedIndices.filter { $0 < destination }.count
songs.insert(contentsOf: selectedSongs, at: adjustedDestination)
```

Then, depending on whether a `playlist` was passed:
- **playlist given** → write `songs`' ids to that playlist, save, and refresh `playbackQueue` **only if** `!playingFromSongsTab`
- **no playlist** → write to `displayedSongs` and to the **master** playlist, and refresh `playbackQueue` **only if** `playingFromSongsTab`

That asymmetry is deliberate but undocumented in-code; the `playingFromSongsTab` flag records which list the user started playback from.

---

## 8. DEBUG metrics

`EngineDebugMetrics` (`audio_engine_protocol.swift:5-15`) is exposed on the protocol and backed by three `#if DEBUG` counters in `AppleAudioEngine` (`:22-26`):

| Metric | Accumulator | Update |
|---|---|---|
| `starveCount` | `debug_starveCount` (`:23`) | `&+= 1` on any true underrun (`:233`) |
| `maxScheduledAhead` | `debug_maxScheduledAhead` (`:24`) | high-water mark of `scheduledBuffersCount` (`:217-218`) |
| `avgScheduleMs` | `debug_avgScheduleMsEWMA` (`:25`) | EWMA of `scheduleBuffersIfNeeded` duration, α = `0.2` (`:253-255`, `debug_ewmaAlpha` at `:26`) |

In Release all three are zeroed (`debugMetrics` at `:379-389`). The consumer is `AudioHealthHUD` (`AudioHealthHUD.swift`), which is DEBUG-only (`:3`) and **not attached to any view** — see [14-known-issues.md](14-known-issues.md#d3-unused-audiohealthhud).

Practical interpretation:
- `maxScheduledAhead` should sit at 5. Lower means buffers are being consumed faster than they are produced, i.e. the read loop is keeping up (healthy). A value pinned at 5 with rising `starveCount` means the read loop is too slow.
- `avgScheduleMs` above ~10 ms per refill at 44.1 kHz means the disk read path cannot sustain 1.25 s of headroom.

---

## 9. Session and interruption handling

`Services/AudioSessionService.swift`.

### Session configuration (`:16-26`)

```swift
try audioSession.setCategory(.playback, mode: .default)
try audioSession.setActive(true)
UIApplication.shared.beginReceivingRemoteControlEvents()
```

`.playback` + `UIBackgroundModes: ["audio"]` (`Punches3-Info.plist:4-6`) is what keeps audio running when locked or backgrounded. `setActive` is also called redundantly in `AudioPlaybackService.play` (`:30-31`) and deactivated in `stop` (`:71`).

### Remote command centre (`:28-68`)

Five handlers: `playCommand` (`:31-38`, **fails if nothing is loaded**), `previousTrackCommand` (`:40-46`), `nextTrackCommand` (`:47-53`), `pauseCommand` (`:54-58`), `changePlaybackPositionCommand` (`:59-67`, scrubs). Targets are added in `setupAudioSession` and **never removed** — they are `[weak self]`, so a stale command is a no-op, but the handlers accumulate if `setupAudioSession` were ever called twice.

> **⚠️ Registration itself can silently not happen.** `setupRemoteTransportControls()` is called from **inside** the same `do` block as two throwing session calls (`AudioSessionService.swift:16-26`). If either `try` throws, control jumps to the `catch` at `:23`, which only `print`s — and **no target is ever added**. The lock screen, Control Center, and headphone buttons are then permanently inert. This is called from `AudioManager.init` (`:87`) at launch, before the engine is initialised, which is exactly the state where `setActive(true)` is most likely to fail. See [14 · E16](14-known-issues.md#e16-remote-commands-are-registered-inside-the-session-setup-do-block).

Three defects apply even when registration succeeds:

| Handler | Defect | Evidence |
|---|---|---|
| `playCommand` | calls `togglePlayPause()` — a **toggle**, not a play. Apple's contract is "begin or resume", so any disagreement between `engine.isPlaying` and what the user expects makes **Play** pause. | `:34`; branch at `AudioPlaybackService.swift:80` |
| `nextTrackCommand` / `previousTrackCommand` | return `.success` **unconditionally**, even when the skip was a no-op (empty queue, track not in queue). The system is told the command worked. | `:41-45`, `:48-52` |
| `changePlaybackPositionCommand` | calls `seek` with no check that anything is playing, so the scrubber moves with no audio. | `:59-67` |

Note that `pauseCommand` (`:55`) uses the same `togglePlayPause()` as `playCommand`, so both buttons share the defect and there is no state in which the pair behaves symmetrically.

### Four notification observers

| Observer | Lines | Behaviour |
|---|---|---|
| `.AVAudioEngineConfigurationChange` | `:70-88` | If playing, `prepare()` + `start()` the engine. Fires on route/format changes. |
| `AVAudioSession.interruptionNotification` | `:90-123` | `.began` → set `isPlaying = false`, invalidate the timer, `engine.pause()`. **Does not touch `currentlyPlayingID` or `MPNowPlayingInfoCenter`.** `.ended` → *only if* `.shouldResume` is set: re-activate the session, `engine.play()`, `isPlaying = true`, `startTimer()`. `.ended` **without** `.shouldResume` — the normal outcome for a phone call — does nothing at all. |
| `AVAudioSession.routeChangeNotification` | `:125-146` | `.oldDeviceUnavailable` (headphones unplugged) → pause, `isPlaying = false`, `stopTimer()`, refresh now-playing. **Does not auto-resume**, which is the correct iOS behaviour. |
| `didEnterBackground` / `willEnterForeground` | `:148-175` | Background: deactivate the session only if *not* playing, then update now-playing. Foreground: re-activate if anything is loaded — **but never restarts the engine or the timer**, so it does not repair a stalled interruption. |

All four tokens are appended to `manager.observerTokens` and removed in `AudioManager.deinit` (`:101-110`).

> **⚠️ A phone call leaves the app reading as "still playing".** The `.began` branch writes `manager.isPlaying = false` but never re-publishes `MPNowPlayingInfoCenter`, so `MPNowPlayingInfoPropertyPlaybackRate` keeps its last value of `1.0` (`:186`) and Control Center shows the track as live. The app's own flag is correct; the *published* one is stale. In the app, `currentlyPlayingID` survives and `currentTime` freezes because the timer was invalidated. Since `.ended` arrives without `.shouldResume`, the timer stays dead and the user must tap play/pause to recover. `stop()` (`AudioPlaybackService.swift:63-75`) never clears `nowPlayingInfo` either, so the identical symptom appears whenever the queue ends. See [14 · E14](14-known-issues.md#e14-an-interruption-leaves-state-that-reads-as-still-playing).

> **Gotcha:** `.ended` interruption calls `self.manager.playbackService.startTimer()` and `.oldDeviceUnavailable` calls `self.manager.sessionService.updateNowPlayingInfo()` — services reaching into *sibling* services via the manager, rather than through the manager façade. This is why the services are `lazy var` and never `nil`. Keep that in mind before you make them non-lazy or reorder their initialisation.

> **Gotcha:** the two `gotcha` items above are unrelated to the registration failure in the remote-command section — `setupInterruptionObserver()` is called on its own at `audio_manager.swift:90`, **outside** the `do` block. A thrown `setActive` makes remote commands inert but leaves interruptions handled normally. Do not merge those two investigations.

### Now-playing info (`:177-202`)

Sets title, duration, elapsed time and playback rate on `MPNowPlayingInfoCenter`. Artwork is cached in `cachedArtwork`/`cachedArtworkID` (`:13-14`) and only re-decoded when `currentlyPlayingID` changes (`:188-196`) — because `loadArtworkImage` is a synchronous disk read.

---

## 10. Change checklist

| If you change… | Re-verify |
|---|---|
| `buffersAhead` or `bufferDuration` | headroom = `buffersAhead × bufferDuration`; the DEBUG `maxScheduledAhead` expectation is 5 |
| `currentTime` derivation | `AudioPlaybackService`'s `currentTime >= duration` auto-advance and the seek-slider binding |
| `seek` | the 3-second previous rule, `seekOffset`/`currentFramePosition` pairing, and the `isSeeking` debounce |
| `play()` | `AudioEngineService.changeAlgorithm` re-entry (`Services/AudioEngineService.swift:55-70`) |
| the tap location or the engine graph | [05-signal-analysis.md](05-signal-analysis.md) — the analyser taps `mainMixerNode` output, i.e. **post** time/pitch, so `sampleRate` follows the mixer format not the file format |
| `onPlaybackFinished` wiring | the *other* end-of-track detector in `AudioPlaybackService.startTimer` (`:134-136`) |
