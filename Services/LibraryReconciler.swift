import Foundation
import os

/// Move-only garbage collection, replacing `cleanupOrphanedFiles`.
///
/// ## What it replaces, and why that mattered
///
/// The old rule was *"delete anything in the library directory that is not in
/// the index"*, with one hardcoded exemption for the literal name `"Artwork"`.
/// Because the index was a JSON blob that decoded all-or-nothing, "not in the
/// index" also meant "the decode failed" — so a routine relaunch after a schema
/// change turned a bookkeeping error into a deleted library. And since the
/// directory it swept was the **Documents root** whenever the app-group
/// entitlement was absent, the blast radius was every file the user had in
/// Documents.
///
/// The rule here is the inverse. The index is authoritative and disk is
/// reconciled toward it, but reconciliation only ever *moves*: nothing in this
/// type calls `removeItem`. Unrecognised bytes go to `Trash/`, where they stay
/// until the user empties it.
///
/// It is deliberately **not** run from `AudioManager.init`. Side-effecting
/// startup with filesystem deletion is what made the old version dangerous.
struct LibraryReconciler {

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "reconciler"
    )

    let environment: LibraryEnvironment
    let store: LibraryStore

    /// How long an unrecognised file must sit untouched before it may be moved
    /// to Trash. Long enough to cover a restore from backup, which can take
    /// days and can arrive out of order.
    static let defaultGracePeriod: TimeInterval = 14 * 24 * 60 * 60

    /// What a reconciliation pass did, including — importantly — what it
    /// deliberately did not touch.
    struct Summary {
        var markedMissing: [UUID] = []
        var restoredMembership: Int = 0
        var movedToTrash: [URL] = []
        var leftAlone: [URL] = []

        var isQuiet: Bool {
            markedMissing.isEmpty
                && restoredMembership == 0
                && movedToTrash.isEmpty
        }
    }

    // MARK: - Entry point

    /// Reconciles the filesystem with the store. Safe to call repeatedly.
    ///
    /// - Parameter reclaimGracePeriod: Untracked files younger than this are
    ///   reported in `leftAlone` and never moved.
    func reconcile(
        reclaimGracePeriod: TimeInterval = LibraryReconciler.defaultGracePeriod
    ) -> Summary {
        var summary = Summary()

        // Order matters. Membership is repaired *before* missing files are
        // marked, so a track that is only invisible (its file is present) is
        // repaired rather than misreported as gone.
        summary.restoredMembership = restoreOrphanedMembership()
        summary.markedMissing = markMissingTracks()

        var untracked = reclaimUntrackedFiles(
            gracePeriod: reclaimGracePeriod,
            summary: &summary
        )
        reclaimStagedFiles(gracePeriod: reclaimGracePeriod, summary: &summary)

        untracked.sort { $0.path < $1.path }

        if !summary.isQuiet {
            Self.logger.notice(
                """
                Reconciled: \(summary.markedMissing.count) missing, \
                \(summary.restoredMembership) re-linked, \
                \(summary.movedToTrash.count) to Trash, \
                \(untracked.count) left alone
                """
            )
        }

        return summary
    }

    // MARK: - Membership self-heal

    /// Re-adds committed tracks that have no row in the master playlist.
    ///
    /// This is the fix for "the file is on disk and in the index, but the song is
    /// not in the list". `sortedAudioFiles` is driven entirely by the master
    /// playlist's ids, so a track missing from it is unreachable no matter how
    /// many times the view recomputes. It used to be caused by an import whose
    /// membership write sat inside a `guard`; now the membership write shares a
    /// transaction with the track insert, and this is the belt to that braces.
    @discardableResult
    func restoreOrphanedMembership() -> Int {
        guard let masterID = try? store.loadMasterPlaylistID(), let masterID else {
            return 0
        }

        guard let orphans = try? store.loadOrphanedTrackIDs(masterID: masterID),
              !orphans.isEmpty
        else {
            return 0
        }

        var restored = 0
        for trackID in orphans {
            do {
                if try store.ensureMembership(trackID: trackID, in: masterID) {
                    restored += 1
                }
            } catch {
                Self.logger.error(
                    "Could not re-link \(trackID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if restored > 0 {
            Self.logger.notice("Restored membership for \(restored) track(s)")
        }
        return restored
    }

    // MARK: - Missing tracks

    /// Flags committed tracks whose file is not on disk.
    ///
    /// The old code dropped these rows from the projection and said nothing,
    /// which made a relocated or evicted file indistinguishable from a failed
    /// import. They are now kept and flagged, so the UI can offer a re-link.
    @discardableResult
    func markMissingTracks() -> [UUID] {
        guard let committed = try? store.loadTracks() else { return [] }

        var missing: [UUID] = []
        for record in committed {
            guard record.state == .committed else { continue }

            let url = environment.tracks.appendingPathComponent(record.fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }

            do {
                try store.setTrackState(record.id, .missing)
                missing.append(record.id)
            } catch {
                Self.logger.error("Could not flag \(record.id.uuidString, privacy: .public) missing")
            }
        }

        for id in missing {
            Self.logger.notice("Track \(id.uuidString, privacy: .public) is missing from disk")
        }
        return missing
    }

    // MARK: - Reclamation

    /// Files in `Tracks/` that no committed row claims.
    ///
    /// These are almost always leftovers from a pre-store version of the app, or
    /// bytes written by an import that died before its commit transaction. They
    /// are *moved* to Trash, never unlinked, and only once past the grace period.
    private func reclaimUntrackedFiles(
        gracePeriod: TimeInterval,
        summary: inout Summary
    ) -> [URL] {
        guard let claimed = try? store.loadCommittedFileNames() else {
            Self.logger.error("Could not read committed file names; skipping reclaim")
            return []
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: environment.tracks,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var deferred: [URL] = []
        let now = Date()

        for url in entries {
            let name = url.lastPathComponent
            guard claimed[name] == nil else { continue }

            if let moved = moveToTrashIfStale(url, gracePeriod: gracePeriod, now: now, summary: &summary) {
                _ = moved
            } else {
                summary.leftAlone.append(url)
                deferred.append(url)
            }
        }

        return deferred
    }

    /// Bytes sitting in `Staging/` that no live import job refers to.
    ///
    /// Staging is by definition transient, so it gets a much shorter grace
    /// period than `Tracks/` — an abandoned partial copy has no value, only
    /// clutter.
    private func reclaimStagedFiles(
        gracePeriod: TimeInterval,
        summary: inout Summary
    ) {
        let stagingGrace = min(gracePeriod, 24 * 60 * 60)

        guard let liveJobs = try? store.loadResumableImportJobs() else { return }
        let claimedStaged = Set(liveJobs.compactMap(\.stagedName))

        for directory in [environment.staging, environment.inbound] {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where !claimedStaged.contains(url.lastPathComponent) {
                if moveToTrashIfStale(url, gracePeriod: stagingGrace, now: Date(), summary: &summary) == nil {
                    summary.leftAlone.append(url)
                }
            }
        }
    }

    @discardableResult
    private func moveToTrashIfStale(
        _ url: URL,
        gracePeriod: TimeInterval,
        now: Date,
        summary: inout Summary
    ) -> URL? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modified = values?.contentModificationDate ?? .distantPast

        guard now.timeIntervalSince(modified) >= gracePeriod else { return nil }

        guard let moved = try? moveToTrash(url, reason: "untracked") else {
            Self.logger.error("Could not move \(url.lastPathComponent, privacy: .public) to Trash; left in place")
            return nil
        }

        summary.movedToTrash.append(moved)
        Self.logger.notice("Moved untracked \(url.lastPathComponent, privacy: .public) to Trash")
        return moved
    }

    // MARK: - Trash

    /// Moves a file into `Trash/`, keeping its name recognisable.
    ///
    /// A *move*, always. If it fails, the caller is expected to leave the file
    /// where it is and log — the failure mode here is a stale file, not a lost
    /// one, and that is the whole point of the redesign.
    @discardableResult
    func moveToTrash(_ url: URL, reason: String) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(stamp)-\(reason)-\(url.lastPathComponent)"
        var destination = environment.trash.appendingPathComponent(name)

        // Two files trashed in the same second must not collide.
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = environment.trash
                .appendingPathComponent("\(stamp)-\(reason)-\(suffix)-\(url.lastPathComponent)")
            suffix += 1
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            Self.logger.error(
                "Trash move failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Removes the contents of `Trash/`.
    ///
    /// The *only* call in the library layer that unlinks anything, and it only
    /// runs in response to an explicit user action.
    func emptyTrash() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: environment.trash,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for url in entries {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                Self.logger.error(
                    "Could not remove trashed \(url.lastPathComponent, privacy: .public)"
                )
            }
        }

        Self.logger.notice("Emptied Trash: \(removed) file(s)")
        return removed
    }

    /// How many files are currently recoverable from Trash.
    func trashCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: environment.trash,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.count ?? 0
    }

    /// Moves a trashed file back to where it came from.
    func restoreFromTrash(_ url: URL) throws {
        let name = url.lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw CocoaError(.fileReadCorruptFile) }

        let originalName = parts[2]
        var destination = environment.tracks.appendingPathComponent(originalName)

        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (originalName as NSString).deletingPathExtension
            let ext = (originalName as NSString).pathExtension
            destination = environment.tracks.appendingPathComponent(
                ext.isEmpty ? "\(base) (restored \(suffix))" : "\(base) (restored \(suffix)).\(ext)"
            )
            suffix += 1
        }

        try FileManager.default.moveItem(at: url, to: destination)
    }
}
