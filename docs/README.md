# Punches Documentation

Fourteen reference documents describing how the Punches audio-visualiser app is built, how it is meant to work, and where it does not work. Every claim is tied to a specific file and line range, and every defect is registered with a severity and a fix.

## Read these first

Two documents change how you should read everything else:

1. **[03 — Project Structure & Build](03-project-structure-and-build.md)** — how the `Punches3` target collects its sources, and the trap in `membershipExceptions`. Target membership has since been repaired: `AudioEngines`, `AudioMeters`, `Services` and `View` are now listed in the target's `fileSystemSynchronizedGroups`, so **every Swift file the app ships compiles** and both the simulator and device builds succeed. `Tests/` and `UITests/` are bound to the *test* targets instead, so no test code can ship ([03 §5.5](03-project-structure-and-build.md#55-the-test-folders-are-bound-to-the-test-targets-not-the-app)).
2. **[14 — Known Issues & Risks](14-known-issues.md)** — a severity-ranked register of **107 entries** across seven categories — 19 Critical, 36 High, 34 Medium, 18 Low — each with evidence, impact, and fix.

> **Status note.** The library layer described throughout this suite was replaced by the SQLite-backed store merged from `laptop`: `LibraryStore`, `LibrarySchema`, `LibraryMigration`, `LibraryReconciler`, `LibraryImportPipeline` and `LibraryImportReport` are new, `cleanupOrphanedFiles` is gone, and the library root is an app-owned subdirectory rather than the Documents root. Entries **C1**, **C2**, **C3**/**E6**, **C12** and **G1**/**A4**/**G1.3** are addressed by that work; treat their entries as historical.

## The documents

| # | Document | What it covers |
|---|---|---|
| 01 | [Getting Started & Usage](01-getting-started-and-usage.md) | What the app is, how to build it, and how to drive every screen — plus what appears to work but does not |
| 02 | [Architecture](02-architecture.md) | Layer map, the 7-service `AudioManager` façade, threading model, and the invariants not to break |
| 03 | [Project Structure & Build](03-project-structure-and-build.md) | Repository layout, targets, build settings, dependencies, target membership, entitlements, schemes |
| 04 | [Audio Pipeline](04-audio-pipeline.md) | `AVAudioEngine` graph, buffer scheduling, playback state machine, seeking, queue and skip logic |
| 05 | [Signal Analysis](05-signal-analysis.md) | Tap → ring buffers → FFT → bands → published arrays, and the two incompatible spectrum paths |
| 06 | [Visualisation (Metal)](06-visualisation.md) | The 128-band Q3 spectrum and multi-band goniometer renderers, pipelines, draw passes, hand-offs |
| 07 | [Meters & HUD](07-meters-and-hud.md) | `VisualisationMode`, the mode picker, the player screen, SwiftUI → Metal data flow, re-render costs |
| 08 | [Playlists & Library](08-playlists-and-library.md) | The hidden `__MASTER_SONGS__` playlist, `AudioLibraryService`, `PlaylistService`, artwork, list views |
| 09 | [File Import & Sharing](09-file-import-and-sharing.md) | Document picker, share extension, app-group contract, share sheet, artwork export |
| 10 | [Theming & Shaders](10-theming-and-shaders.md) | `ThemeManager`, 35 themes, 30 persisted keys, the four `colorEffect` background shaders, quality tiers |
| 11 | [Settings UI](11-settings-ui.md) | `View/setting_View.swift` — screen structure, the quality tiers, and the settings that do not exist |
| 12 | [Persistence and Storage Keys](12-persistence-and-keys.md) | Every persisted byte in the app: keys, on-disk layout, and what survives a relaunch |
| 13 | [Concurrency & Threading](13-concurrency-and-threading.md) | Every thread boundary, the invisible isolation model, real-time allocation, locks, continuations |
| 14 | [Known Issues & Risks](14-known-issues.md) | 107 ranked defects and dead paths with evidence, impact, and fix, plus a symptom → issue table |

## Suggested reading paths

- **New to the codebase** — [01](01-getting-started-and-usage.md) → [02](02-architecture.md) → [03](03-project-structure-and-build.md), then the area you are changing.
- **You have a bug report, not a task** — [14 · Reported symptoms](14-known-issues.md#reported-symptoms) maps a plain-language symptom to the issue entry. Start there rather than searching for code.
- **Fixing the build** — [03 §5](03-project-structure-and-build.md#5-target-membership-and-the-trap-in-it) → [03 §8](03-project-structure-and-build.md#8-building-and-verifying) → [14 A](14-known-issues.md#a--build--project-structure).
- **Making the app-group handoff work** — [14 A3](14-known-issues.md#a3-app-group-entitlement-is-empty) → [09 §2](09-file-import-and-sharing.md#2-sharedconstants) → [12 §3](12-persistence-and-keys.md#3-app-group-keys).
- **Working on audio** — [04](04-audio-pipeline.md) → [05](05-signal-analysis.md) → [13](13-concurrency-and-threading.md).
- **Working on rendering** — [05](05-signal-analysis.md) → [06](06-visualisation.md) → [07](07-meters-and-hud.md).
- **Working on the library or playlists** — [08](08-playlists-and-library.md) → [12](12-persistence-and-keys.md) → [09](09-file-import-and-sharing.md).
- **Working on appearance** — [10](10-theming-and-shaders.md) → [11](11-settings-ui.md) → [12 §4](12-persistence-and-keys.md#4-theme-keys--all-30).
- **Changing anything persistent** — [12](12-persistence-and-keys.md) is the canonical key inventory and must be updated in the same change.
- **Changing queue or track-advance behaviour** — [04 §7](04-audio-pipeline.md#7-queue-skip-and-loop) → [14 · E15](14-known-issues.md#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song) → `Tests/PlaybackContinuationTests.swift`. Read the tests first: they are the only executable statement of the queue rules, and they were mutation-checked, so a green run is worth something.

## Conventions

- Citations are written `` `path/File.swift:123-456` ``. A bare `` `:456` `` continues the file named most recently in the same paragraph.
- Line ranges point at the enclosing implementation, not the exact statement, so they stay useful under small edits.
- Findings are labelled by severity: **Critical**, **High**, **Medium**, **Low**. See [14 §Severity scale](14-known-issues.md#severity-scale).
- Issue entries carry an **Exploration notes** block: hypotheses already ruled out, how to confirm the rest, and any trap for the next reader. Read it before investigating — it is there so a failed approach is not repeated. All Critical and High entries currently have one; Medium and Low do not yet, and should gain one as each is picked up.
- Documents describe the code as written. Where intent and behaviour diverge, both are stated.

## Known inaccuracies in the root `README.md`

The repository's top-level `README.md` is out of date in ways the register documents: it claims three visualisation modes where the code has four, describes goniometer filtering that does not exist, and states requirements a decade out of step with the deployment target. These are filed as [D10](14-known-issues.md#d10-the-root-readmemd-requirements-are-wrong-by-a-decade) and [D11](14-known-issues.md#d11-the-root-readmemd-overstates-the-goniometers-filtering). The root README is left unmodified by this documentation set.
