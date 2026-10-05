# 04 — Audio Pipeline

> Everything from the `AVAudioEngine` graph down to individual `AVAudioPCMBuffer` scheduling. This is the doc for anyone changing playback, seeking, buffering or pitch/tempo.
> Companion: [05-signal-analysis.md](05-signal-analysis.md) (what happens to the tapped samples).

---

## 1. The engine graph

Built in `AppleAudioEngine.setupAudioEngine()` (`AudioEngines/AppleAudioEngine.swift`):

```
AVAudioPlayerNode ──► AVAudioUnitTimePitch ──► mainMixerNode ──► output
  (file playback)      (rate + pitch)          (tap installed here,
                                              bufferSize = hopSize)
```

### `init()` attaches only. It does not start, connect to the mixer, or prepare.

This is the single most surprising thing about the graph, and it is deliberate.

Reading `audioEngine.mainMixerNode` initialises the IO unit. When the audio
hardware does not answer in time, AudioToolbox reports it through
`_ReportRPCTimeout` → `abort()` **from inside the accessor** — not as an error,
so there is nothing to throw and nothing to catch. Calling
`audioEngine.start()` fails the same way. `prepare()` on a graph whose chain ends
at `timePitch` raises an `NSException` from `AVAudioEngineGraph::Initialize`,
which is also uncatchable from Swift.

`setupAudioEngine()` used to do all three, in a `do`/`catch`, at launch. The
`catch` clauses were unreachable for the failures that actually occur, so the app
could die inside `AudioManager.init()` — before the session was configured,
before any playback code ran, and before anything could be shown or logged.

Now `init()` attaches the two nodes and connects `playerNode → timePitch`.
`reconfigureGraphIfNeeded` makes the mixer edge on the first file that needs it,
`prepare()` is called there and in `play()`, and `play()` starts the engine. **An
app that is launched and never played touches no audio hardware at all.**

There is an `isOutputConnected` flag guarding the mixer edge, and it is
load-bearing. `reconfigureGraphIfNeeded` normally returns early when the format
already matches — and on a fresh engine the placeholder `playerNode → timePitch`
connection adopts the session's rate, so **any file already at that rate would
skip the reconfigure and leave the graph with no path to the speakers.** The guard
is `!alreadyCorrect || !isOutputConnected`. A regression here is completely
silent: no error, no log, just no sound for files matching the session rate.

### Why `playerNode → timePitch` is seeded with `format: nil`

`timePitch → mainMixerNode` is seeded with `format: nil` so the mixer converts to
whatever the hardware is doing. **`playerNode → timePitch` is not left at `nil`**
(it is, but it is replaced before anything plays): a node's output format is fixed
by its connection and `AVAudioPlayerNode` inserts no sample-rate converter, so a
`nil` connection left in place pins the player to the session rate and plays every
mismatched file at the wrong speed *and* pitch.

`reconfigureGraphIfNeeded` therefore reconnects **both** edges in the file's
`processingFormat` on every load, letting the mixer do the conversion. Both edges
are required, and the second one is the subtle half: **`AVAudioUnitTimePitch`
pins its own output rate at connect time and does not follow its input.**
Reconnecting only the player edge leaves the unit rendering at its original rate,
so the mismatch is relocated one node downstream and the detune is unchanged — the
player's format is the one that updates, which is exactly why guarding on it looks
correct and is not. The guard reads `timePitch.inputFormat(forBus: 0)` instead, the
junction between the two nodes and the format that actually stuck. See [E17](14-known-issues.md).

Whichever way the edges above are connected, `mainMixerNode`'s **output** format
stays at the hardware rate — which matters, because that is the bus the analyser taps.

The mixer output format — and therefore the tap format — is only valid *after* the
engine has been prepared and started.

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
        // A buffer's completion says "I finished playing". It does not say
        // "I still belong to the track you are on now" — see PlaybackRun below.
        guard let self, self.playbackRun.current == run else { return }
        guard !self.isUserStopped else { return }      // ← early-out for stop()
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

Four things to understand here:

- **`isUserStopped` cannot do this job alone.** It is a per-engine `Bool` that the next `load` resets, so it can express "we stopped" but not "the track this buffer belonged to is no longer the current one". `PlaybackRun` supplies that. See below.
- **The `isUserStopped` early-out prevents the refilling recursion from resurrecting a stopped engine.** Without it, a completion callback already in flight after `stop()` would call `scheduleBuffersIfNeeded` and queue audio that never plays.
- **Starvation definition** is precise: buffers reached zero *while the player node was actually playing* and *not at end of file*. It counts real underruns, not the normal moment between the last buffer of a file and end-of-stream handling.
- **End-of-file detection requires `atEnd && scheduledBuffersCount == 0`**, i.e. the final buffer has actually been *rendered*, not merely queued. `onPlaybackFinished` then hops to main before firing, so the skip-next chain runs on the main actor.

### `PlaybackRun` — the generation token

```swift
final class PlaybackRun {
    private var value = UUID()
    func begin() -> UUID { value = UUID(); return value }   // bump and return the new token
    var current: UUID { value }                             // read only — must NOT bump
}
```

Every buffer captures the token of the run that scheduled it and discards itself
inside `audioQueue` if the engine has moved on. `load`, `stop` and `seek` all
bump it.

**This replaced clearing `onPlaybackFinished` in `stop()`/`load()`,** which was
the originally prescribed fix and is wrong. `AudioPlaybackService` reassigns that
closure from the main thread immediately after calling `load()`, while the
engine's `load()` body is still sitting unstarted on `audioQueue` — so clearing it
there races the reassignment and can wipe the closure the *new* track needs. The
token is checked on `audioQueue` and cannot race. Clearing the closure was never
sufficient anyway: the damage is to `scheduledBuffersCount`, which a cleared
closure does not restore.

**`current` must not bump the token.** It does not, and there is a test pinning
that, because getting it wrong is silent and fatal: if reading the token bumped
it, then `scheduleBuffersIfNeeded` — which reads it on every pass — would
invalidate the buffers the previous pass had just scheduled, and playback would
die after the first five buffers with no error. That is a real bug this invariant
caught during implementation.

**`seek()` is the case that proves it is needed.** `seek` calls `playerNode.stop()`,
which flushes every pending buffer *without playing it* — up to 5 of them. The
system still calls their handlers. Those run on `audioQueue` *behind* `seek`'s own
work, arriving after `seek` has already reset `scheduledBuffersCount` for the new
position, so each decremented it a second time. If the flushed run's last buffer
had `atEnd`, then `atEnd && scheduledBuffersCount == 0` went true on the
*rescheduled* run — so scrubbing near the end of a track skipped it, sometimes
skipping the track that had just started as well. See
[14-known-issues.md](14-known-issues.md#e18-seeking-near-the-end-of-a-track-advanced-the-queue).

### An alternative that was considered and rejected

`AVAudioPlayerNode.scheduleFile(_:at:completionCallbackType:)` would hand the whole
file to the player node and remove the 5 × 0.25 s scheduler, the completion
recursion and this entire class of stale-callback bug. It was not adopted because
the analyser taps `mainMixerNode` and a file-backed schedule changes the render
path enough to risk starving the tap — and a dead visualiser is a worse regression
than the bookkeeping it removes. Worth revisiting if the tap ever moves off the
mixer.

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

> **`duration` uses `processingFormat` too** (`:46`: `file.length / file.processingFormat.sampleRate`), matching `seek` and `currentTime`. It used to divide by `fileFormat.sampleRate` instead — the on-disk stream rate, which is lower whenever the decoder up-samples, HE-AAC being the common case (encodes at 22.05/24 kHz, decodes to 44.1/48 kHz). That reported roughly double the real duration and disagreed with the seek clock on exactly the files most likely to have it; see [E17](14-known-issues.md).
>
> **There is now one duration clock.** `manager.duration` used to be set from `AudioFile.audioDuration`, captured at import time, and compared against this render clock — two sources of truth that could disagree. The first tick after a load now publishes `engine.duration` (`needsDurationSync`), so the position and the length it is compared against come from the same place.

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

`AudioPlaybackService.startTimer()` polls this at **0.2 s** and does exactly three things:

- skips entirely while `manager.seekSuppressedUntil` is in the future
- writes `manager.currentTime` every tick
- refreshes `MPNowPlayingInfo` only when the integer second changes

It does **not** decide when a track has ended. See §7.

### The tick is a `DispatchSourceTimer`, not a `Timer`

```swift
private let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(50))
timer.resume()      // exactly once — a dispatch source that is never resumed never fires
```

This is not a stylistic preference. `Timer.scheduledTimer(withTimeInterval:repeats:)` adds to the current run loop in **`.default` mode**, and `.default`-mode timers are suppressed for the duration of any mode change — every scroll, every scrubber drag — and throttled by the system once the app is backgrounded. For a progress bar that is cosmetic; when the tick also decided auto-advance, it was the difference between advancing and not. See [14-known-issues.md](14-known-issues.md#e19-the-progress-timer-is-a-run-loop-timer-so-it-stops-when-it-matters).

`.common` mode was the alternative and was rejected: it helps while foregrounded but is still throttled in the background, and it requires every run-loop mode change to keep it correct. A dispatch source has no run-loop mode to keep in sync.

`AudioManager.timer` changed type to `DispatchSourceTimer?` to match, and `deinit` calls `cancel()`. A dispatch source that is never `resume()`d never fires, and one that is never `cancel()`d leaks its queue slot — both are easy to get wrong.

### `seekSuppressedUntil`, not `isSeeking`

The suppression window is a **monotonic deadline** (`CACurrentMediaTime() + 0.15`), compared against the clock, rather than a `Bool` set `true` by `seek()` and cleared by a `DispatchQueue.main.asyncAfter`.

The `Bool` latched. If the app were suspended inside that 0.15 s window — which is exactly what happens when the device locks mid-drag — the clearing block never ran, `startTimer()`'s `guard` returned early **for the rest of the session**, and the progress bar and lock-screen position were dead with no way to recover. A deadline cannot latch: it expires whether or not anything runs.

> **There is no second end-of-track detector.** This used to be true and was the root of a class of double-advance bugs. The timer's `currentTime >= duration` branch has been deleted; the engine's last-buffer completion is the only signal. See §7 and [14-known-issues.md](14-known-issues.md#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song).

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

### One advance, and where the decision lives

Every reason to move the queue on — a track ending, the Next button, the remote
next command — goes through **one** method:

```swift
@discardableResult
func advance(_ reason: PlaybackAdvanceReason) -> Bool
```

`PlaybackAdvanceReason` is `.trackFinished`, `.nextCommand` or
`.previousCommand`, and exists so the entry point records *why* it was called.
There is an in-flight guard (`advanceInFlight`) for the case where two signals
arrive close together.

> **Why one method.** This used to have two racing callers: the engine's
> last-buffer completion and the progress timer's `currentTime >= duration`
> check. Both ran a non-re-entrant `skipNextSong`, and whichever lost the race
> issued a second, unwanted advance. The timer's branch has been deleted — see
> [14-known-issues.md](14-known-issues.md#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song).

### `PlaybackQueuePlanner` — the decision, with no engine

The queue rules are a **pure function** returning an action carrying a `UUID`:

```swift
enum PlaybackQueueAction: Equatable {
    case playTrack(UUID)     // start this id, with the queue as context
    case restartCurrent(UUID)// same id, from zero
    case stop
}

static func action(queue: [AudioFile], currentID: UUID?, currentTime: TimeInterval, isLooping: Bool) -> PlaybackQueueAction
```

The pseudocode it replaces:

```
queue empty                              → stop
currentID == nil                         → playTrack(queue[0])
current track not in queue               → playTrack(queue[0])

── previous ──
currentTime > 3.0                        → restartCurrent(currentID)
index == 0                               → restartCurrent(currentID)
                                          → playTrack(queue[index - 1])

── next ──
index + 1 < queue.count                  → playTrack(queue[index + 1])
isLooping                                → playTrack(queue[0])   // repeat the QUEUE
                                          → stop
```

Extracting it is what makes the rules testable without a live `AVAudioEngine`,
an `AVAudioSession` or a Simulator: `Tests/PlaybackContinuationTests.swift`
covers all of the above, plus the boundary at exactly 3.0 s, in milliseconds.

**The threshold is `> 3.0`, not `>= 3.0`** — at exactly three seconds you go
back. That is the conventional behaviour of every music player and is pinned by
a test, because it is a one-character change nobody notices.

### Loop means repeat the *queue*

`isLooping` is the only loop mode and it has exactly one reader: the end-of-the-queue
case. There is no repeat-one. A single-item playlist with looping on spins that
item forever.

The UI button renders `repeat` with the accent tint when set — it used to render
`repeat.1`, which advertised repeat-one and never existed. The flag is also
persisted, so the toggle survives a relaunch. See
[14-known-issues.md](14-known-issues.md#d1-loop-is-honoured-only-at-the-end-of-the-queue).

### `skipPreviousSong()` / `skipNextSong()`

Both are thin wrappers over `advance(.previousCommand)` / `advance(.nextCommand)`.
They exist because the call sites — the player view, `AudioSessionService`'s
remote commands — read better named, and because the wrappers are what the
remote commands report `.commandFailed` against.

`restartCurrentSong()` seeks to zero and **does not start playback**. It used to
ensure the engine was playing, which meant pressing Previous on a paused track
un-paused it.

### Where the loop icon and the tempo slider are not

Tempo is clamped to `0.1 … 4.0` and persisted, but the slider is still commented
out of the player layout, so there is no way to change speed in the shipped app —
see [14-known-issues.md](14-known-issues.md#d2-tempo-control-is-commented-out).
`setVolume` is not exposed either.

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

### Session configuration

```swift
// once, at launch
try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
try audioSession.setActive(true)

// per play — activation only, no reconfiguration
guard activateSession() else { scheduleSessionRetry { … }; return }
```

`.playback` + `UIBackgroundModes: ["audio"]` (`Punches3-Info.plist:4-6`) is what
keeps audio running when locked or backgrounded. The **policy** is what says this
is music rather than "an app that plays audio"; it is what gets correct Now Playing
behaviour and AirPlay 2 queueing.

`play()` activates but does not re-run `setCategory`. Reconfiguring the category on
every play was redundant and was another way to throw at a bad moment.

**A failed activation must not return into silence.** `play()` used to `return`
straight out of its `catch`, and because `skipNextSong` had already called
`stopTimer()` and the engine was stopped, the result was: no track playing, no
tick, nothing on screen. `setActive` fails routinely while the system is
mid-transition — the device locking, an interruption being torn down, another app
holding the session — which are exactly the states where an auto-advance bug is
most visible. `activateSession()` now returns `Bool`, logs via `os.Logger`, leaves
the current state intact, and `scheduleSessionRetry` re-enters `play()` with the
same arguments after 0.5 s, bounded at 2 retries.

`stop()` deactivates the session with `.notifyOthersOnDeactivation`.

### Remote command centre

Six handlers: `playCommand` → `resumePlayback()`, `pauseCommand` →
`pausePlayback()`, `togglePlayPauseCommand`, `previousTrackCommand` and
`nextTrackCommand` → `advance(...)`, `changePlaybackPositionCommand` (scrubs).

**Play is not a toggle.** Apple's contract for `playCommand` is "begin or resume".
It used to call `togglePlayPause()`, so any disagreement between
`engine.isPlaying` and what the user expected made the lock-screen Play button
*pause* the track. `pauseCommand` has the same contract. `togglePlayPause` is
registered separately for the case where the system genuinely means toggle.

**Skips report honestly.** The skip handlers return `advance(...)`'s result, so a
skip with nowhere to go is `.commandFailed` rather than a claimed success.
`changePlaybackPositionCommand` refuses when `currentlyPlayingID` is `nil`, so the
scrubber no longer moves with no audio behind it.

**Availability tracks the queue.** `updateNowPlayingInfo()` sets
`nextTrackCommand.isEnabled` from the current index and `isLooping`, so Next greys
out at the end of a non-looping queue instead of silently doing nothing.
`stop()` calls `clearNowPlayingInfo()`, which disables everything and clears
`MPNowPlayingInfoCenter` — `updateNowPlayingInfo()` cannot express "no transport",
because it returns early when nothing is loaded.

**Registration is unconditional and idempotent.** `beginReceivingRemoteControlEvents()`
and `setupRemoteTransportControls()` are called outside the `do` block, so a
throwing session call can no longer leave the lock screen permanently inert, and an
`isRemoteControlConfigured` flag stops a second call registering duplicate targets
(duplicate targets are a documented way to have two closures race on one command).

See [14 · E16](14-known-issues.md#e16-remote-commands-are-registered-inside-the-session-setup-do-block).

### Four notification observers

| Observer | Behaviour |
|---|---|
| `.AVAudioEngineConfigurationChange` | If playing, `prepare()` + `start()` the engine. Fires on route/format changes. |
| `AVAudioSession.interruptionNotification` | `.began` → `isPlaying = false`, stop the tick, `engine.pause()`, **and re-publish now-playing** so the rate becomes `0.0`. `.ended` → **re-activate the session either way** (without `.shouldResume`, the normal phone-call outcome, the session used to be left deactivated), then: with `.shouldResume` **and** `isPlaying`, resume; otherwise restart the tick and refresh now-playing, leaving a clean paused-but-resumable state. |
| `AVAudioSession.routeChangeNotification` | `.oldDeviceUnavailable` (headphones unplugged) → pause, stop the tick, refresh now-playing. **Does not auto-resume**, which is the correct iOS behaviour. |
| `didEnterBackground` / `willEnterForeground` | Background: deactivate the session only if *not* playing, then update now-playing. Foreground: re-activate, restart the `AVAudioEngine` if it is not running, then resume or restart the tick. |

All four tokens are appended to `manager.observerTokens` and removed in `AudioManager.deinit`.

`currentlyPlayingID` deliberately survives an interruption. It is the only record
of *what* to resume, and `.ended` carries no other hint. The cost is that it must
be kept in step — which is what re-publishing now-playing in both branches is for.

> **Gotcha:** interruption `.ended` reaches `playbackService.startTimer()` and
> `.oldDeviceUnavailable` reaches `sessionService.updateNowPlayingInfo()` —
> services calling *sibling* services via the manager rather than through the
> manager façade. This is why the services are `lazy var` and never `nil`. Keep
> that in mind before making them non-lazy or reordering initialisation.

### Now-playing info

`updateNowPlayingInfo()` sets title, duration, elapsed time, playback rate **and**
`MPNowPlayingInfoPropertyDefaultPlaybackRate`. The second rate key is the one the
system interpolates the lock-screen scrubber between updates from; without it the
elapsed time visibly steps a second at a time.

Artwork is cached in `cachedArtwork`/`cachedArtworkID` and only re-decoded when
`currentlyPlayingID` changes — because `loadArtworkImage` is a synchronous disk read.

`clearNowPlayingInfo()` is the counterpart used by `stop()`. It disables every
remote command and clears the centre; see §9.

---

## 10. Change checklist

| If you change… | Re-verify |
|---|---|
| `buffersAhead` or `bufferDuration` | headroom = `buffersAhead × bufferDuration`; the DEBUG `maxScheduledAhead` expectation is 5 |
| `currentTime` derivation | the seek-slider binding, and that `duration` is published from `engine.duration` by the first tick after a load — **not** from `AudioFile.audioDuration` at import time |
| `seek` | the 3-second previous rule, the `seekOffset`/`currentFramePosition` pairing, `seekSuppressedUntil`, **and that `seek` still bumps `playbackRun`** — `playerNode.stop()` flushes pending buffers and their completions are still called |
| `load`, `stop` or `seek` | all three bump `playbackRun`. A new one that does not re-introduces the stale-callback skip. Do not clear `onPlaybackFinished` instead — it races the reassignment in `play()` |
| `advance(_:)` or `PlaybackQueuePlanner` | `Tests/PlaybackContinuationTests.swift`, and mutation-check it: a green run does not prove the assertions are real |
| `play()` | `AudioEngineService.changeAlgorithm` re-entry; that it returns *into* a working state on a failed `activateSession()`; and `AudioLibraryService.deleteAudioFile`, which now hands the player to the deleted track's successor |
| `setupAudioEngine()` | that the graph still reaches the speakers — `isOutputConnected` overrides the `alreadyCorrect` early-out, and getting that wrong is silent |
| the tap location or the engine graph | [05-signal-analysis.md](05-signal-analysis.md) — the analyser taps `mainMixerNode` output, i.e. **post** time/pitch, so `sampleRate` follows the mixer format not the file format. The engine no longer starts at init, so `installTapSafely`'s `isRunning` guard is now reached by polling rather than on a fixed delay |
| `onPlaybackFinished` wiring | that **no second** end-of-track detector has crept back in. There is one, in the engine |
| anything in `AudioManager.init` | it must not touch audio hardware. `AppleAudioEngine.init` used to abort the process three different ways; `UITests/Punches3UITests.swift` is the guard |
