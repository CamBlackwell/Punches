import Foundation
import os

/// Resolves every on-disk location the library owns, once per launch, and adopts
/// anything a previous version of the app left behind.
///
/// This replaces the old `AudioManager.fileDirectory`, which was a `static let`
/// resolved against whatever the app-group entitlement state happened to be at
/// first touch, and which fell back to the **Documents root** when the
/// entitlement was absent. That fallback is the reason `cleanupOrphanedFiles`
/// used to sweep a user's entire Documents directory: the "library" it was
/// reconciling against was never an app-owned subdirectory.
///
/// Two rules this type exists to enforce:
///
/// 1. The library always lives in a directory the app owns outright. Even the
///    fallback is namespaced (`Documents/Punches`), never a shared root.
/// 2. Losing the app group is a **loud** condition, not a silent one. The share
///    extension cannot work without it, so the fallback sets
///    `shareExtensionAvailable = false` and logs a fault rather than pretending.
struct LibraryEnvironment {

    /// How the library root was resolved this launch.
    enum Scope: Equatable {
        /// The shared app-group container was available.
        case appGroup(container: URL)
        /// The app group was unavailable, so the library is app-private.
        case documentsFallback(reason: String)
    }

    enum Subdirectory: String, CaseIterable {
        case tracks   // committed audio, one file per library row
        case staging  // in-flight imports, never a library row
        case inbound  // handed over by the share extension, never claimed yet
        case artwork
        case trash
    }

    let scope: Scope
    let root: URL
    let tracks: URL
    let staging: URL
    let inbound: URL
    let artwork: URL
    let trash: URL
    let database: URL

    /// `nil` only if the database could not be opened, in which case the app has
    /// no durable store and every read/write falls back to in-memory behaviour.
    /// Carried as an optional rather than thrown so that a single unreachable
    /// `static let` can never prevent the app from launching.
    let store: LibraryStore?

    /// Whether the share extension can reach this library at all.
    ///
    /// Without the app-group entitlement the extension's `containerURL` is `nil`
    /// and the inbound queue is unreachable, so callers skip the handoff rather
    /// than writing files nobody will ever drain.
    let shareExtensionAvailable: Bool

    /// Move-only garbage collection over this layout.
    var reconciler: LibraryReconciler? {
        store.map { LibraryReconciler(environment: self, store: $0) }
    }

    /// The process-wide layout, resolved once.
    ///
    /// Replaces the old `AudioManager.fileDirectory` `static let`. Like it, this
    /// cannot change within a running process — a rebuild that adds the app-group
    /// entitlement needs a relaunch before the group path takes effect. Unlike
    /// it, the fallback is a directory the app owns rather than the Documents
    /// root, and it is logged.
    static let shared: LibraryEnvironment = {
        do {
            return try resolve()
        } catch {
            logger.fault(
                "Library layout could not be resolved: \(error.localizedDescription, privacy: .public). Falling back to a minimal app-private tree."
            )
            return emergency()
        }
    }()

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "environment"
    )

    /// The library layer's shared logger.
    ///
    /// Exposed so the services and the pipeline log under one subsystem instead
    /// of each inventing its own. The original diagnosis leaned on `print`
    /// statements, which are absent from release builds — a data-loss bug that
    /// only logs in debug is a data-loss bug nobody can debug.
    static var log: Logger { logger }

    /// Last-resort layout: no app group, no store, directories created on a
    /// best-effort basis. The app still launches and still plays; it just cannot
    /// persist a library, and the log says so loudly.
    private static func emergency() -> LibraryEnvironment {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Punches", isDirectory: true)
        let make: (String) -> URL = {
            root.appendingPathComponent($0, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        return LibraryEnvironment(
            scope: .documentsFallback(reason: "layout resolution failed"),
            root: root,
            tracks: make(Subdirectory.tracks.rawValue),
            staging: make(Subdirectory.staging.rawValue),
            inbound: make(Subdirectory.inbound.rawValue),
            artwork: make(Subdirectory.artwork.rawValue),
            trash: make(Subdirectory.trash.rawValue),
            database: root.appendingPathComponent("library.sqlite"),
            store: nil,
            shareExtensionAvailable: false
        )
    }

    /// Extensions treated as importable audio when adopting a legacy layout.
    ///
    /// Deliberately conservative: the migration only *moves* files it can prove
    /// are audio, and leaves everything else alone.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac",
        "alac", "mp4", "m4b", "aiff", "caf",
    ]

    /// Resolves the layout, creating the directory tree.
    ///
    /// - Throws: If the chosen root cannot be created. Callers treat this as
    ///   fatal-for-the-library rather than falling back to a second guess — a
    ///   half-created tree is how files end up untracked.
    static func resolve(fileManager: FileManager = .default) throws -> LibraryEnvironment {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let scope: Scope
        let root: URL

        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        ) {
            root = group.appendingPathComponent("Library", isDirectory: true)
            scope = .appGroup(container: group)
        } else {
            // Never the Documents root. The old fallback returned it verbatim,
            // which meant the "library directory" was the user's own folder.
            root = documents.appendingPathComponent("Punches", isDirectory: true)
            let reason = "containerURL(forSecurityApplicationGroupIdentifier:) returned nil"
            scope = .documentsFallback(reason: reason)
            logger.fault(
                """
                App group \(SharedConstants.appGroupIdentifier, privacy: .public) unavailable \
                (\(reason, privacy: .public)). Library is app-private at \
                \(root.path, privacy: .public); the share extension is disabled. \
                Add com.apple.security.application-groups to Punches3.entitlements.
                """
            )
        }

        let environment = LibraryEnvironment(
            scope: scope,
            root: root,
            tracks: root.appendingPathComponent(Subdirectory.tracks.rawValue, isDirectory: true),
            staging: root.appendingPathComponent(Subdirectory.staging.rawValue, isDirectory: true),
            inbound: root.appendingPathComponent(Subdirectory.inbound.rawValue, isDirectory: true),
            artwork: root.appendingPathComponent(Subdirectory.artwork.rawValue, isDirectory: true),
            trash: root.appendingPathComponent(Subdirectory.trash.rawValue, isDirectory: true),
            database: root.appendingPathComponent("library.sqlite"),
            store: nil,
            shareExtensionAvailable: {
                if case .appGroup = scope { return true }
                return false
            }()
        )

        try environment.createLayout(fileManager: fileManager)

        // Opened after the tree exists, so SQLite never has to create its own
        // parent directories on a path that is still being assembled.
        let store: LibraryStore?
        do {
            store = try LibraryStore(url: environment.database)
        } catch {
            logger.fault(
                "Could not open the library database: \(error.localizedDescription, privacy: .public)"
            )
            store = nil
        }

        let resolved = LibraryEnvironment(
            scope: environment.scope,
            root: environment.root,
            tracks: environment.tracks,
            staging: environment.staging,
            inbound: environment.inbound,
            artwork: environment.artwork,
            trash: environment.trash,
            database: environment.database,
            store: store,
            shareExtensionAvailable: environment.shareExtensionAvailable
        )

        logger.notice("Library root: \(root.path, privacy: .public)")
        return resolved
    }

    /// Every directory this layout owns, in creation order.
    var managedDirectories: [URL] {
        [root, tracks, staging, inbound, artwork, trash]
    }

    func url(for subdirectory: Subdirectory) -> URL {
        switch subdirectory {
        case .tracks: return tracks
        case .staging: return staging
        case .inbound: return inbound
        case .artwork: return artwork
        case .trash: return trash
        }
    }

    private func createLayout(fileManager: FileManager) throws {
        for directory in managedDirectories {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                logger.error(
                    "Could not create \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }

        // Staging and Trash must not be indexed by iCloud/iTunes backups: they
        // hold copies of files that already exist elsewhere, and an interrupted
        // import restored from backup would be a phantom library row.
        for scratch in [staging, inbound, trash] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = scratch
            try? mutable.setResourceValues(values)
        }
    }

    // MARK: - Adoption of a legacy layout

    /// Locations a previous version of the app may have written audio to.
    ///
    /// Enumerated rather than inferred, because the answer depends on the
    /// entitlement state at the time — and that state has changed across
    /// builds. Every one of these is scanned **read-only**; nothing is removed.
    var legacyAudioLocations: [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var locations: [URL] = [
            documents.appendingPathComponent("AudioFiles", isDirectory: true),
            documents,  // the old fallback wrote imported audio directly here
        ]
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        ) {
            locations.append(group.appendingPathComponent("AudioFiles", isDirectory: true))
            locations.append(
                group.appendingPathComponent("PendingImports", isDirectory: true)
            )
        }
        return locations.filter { $0.standardizedFileURL != root.standardizedFileURL }
    }

    /// Audio files sitting in a legacy location, excluding anything the new
    /// layout already owns.
    func legacyAudioFiles(fileManager: FileManager = .default) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()

        for location in legacyAudioLocations {
            let candidates: [URL]
            if let entries = try? fileManager.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                candidates = entries
            } else {
                continue
            }

            for candidate in candidates {
                let standardized = candidate.standardizedFileURL
                let path = standardized.path

                // Never re-adopt something the new layout already tracks.
                if path.hasPrefix(tracks.path) || path.hasPrefix(staging.path)
                    || path.hasPrefix(inbound.path) || path.hasPrefix(trash.path)
                    || path.hasPrefix(artwork.path) {
                    continue
                }

                guard seen.insert(path).inserted else { continue }

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      Self.audioExtensions.contains(
                        candidate.pathExtension.lowercased()
                      ) else {
                    continue
                }

                found.append(standardized)
            }
        }

        return found.sorted { $0.path < $1.path }
    }

    /// Marks the library root for backup.
    ///
    /// The old layout stored the index in `UserDefaults` (backed up) and the
    /// audio in a directory that was not, so a device restore brought back the
    /// index and none of the music.
    func excludeFromBackup(_ excluded: Bool, fileManager: FileManager = .default) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var mutable = root
        try? mutable.setResourceValues(values)
    }
}
