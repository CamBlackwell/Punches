import Foundation

/// Why a source file could not be imported.
///
/// Every one of these used to end in the same place: a `print`, an `importError`
/// string that no view ever read, and a file that silently failed to appear. The
/// app had no way to distinguish "refused" from "never existed", which is why
/// every failure was reported as lost data.
enum ImportFailure: String, Hashable, CaseIterable, LocalizedError {
    /// The app has no security scope for this file.
    case noPermission
    /// iCloud Drive / Files provider had not materialised the bytes.
    case cloudNotDownloaded
    /// AVFoundation could not read a duration — unsupported or damaged.
    case unsupportedCodec
    /// FairPlay-protected; not playable outside its store.
    case drmProtected
    /// Readable, but reported as not playable.
    case notPlayable
    /// Zero, negative, NaN or infinite duration.
    case invalidDuration
    /// The source vanished between selection and copy.
    case sourceVanished
    /// Already in the library.
    case duplicate
    /// Out of space on the volume.
    case diskFull
    /// The source changed while it was being read.
    case sourceChanged
    case cancelled

    var title: String {
        switch self {
        case .noPermission: return "No permission"
        case .cloudNotDownloaded: return "Still downloading"
        case .unsupportedCodec: return "Unsupported format"
        case .drmProtected: return "Protected file"
        case .notPlayable: return "Not playable"
        case .invalidDuration: return "Damaged file"
        case .sourceVanished: return "File no longer there"
        case .duplicate: return "Already added"
        case .diskFull: return "No space left"
        case .sourceChanged: return "File changed while copying"
        case .cancelled: return "Cancelled"
        }
    }

    var detail: String {
        switch self {
        case .noPermission:
            return "The app was not given access to this file."
        case .cloudNotDownloaded:
            return "This file lives in iCloud Drive and had not finished downloading."
        case .unsupportedCodec:
            return "This device could not decode the audio format."
        case .drmProtected:
            return "This track is protected by DRM and cannot be copied."
        case .notPlayable:
            return "The file was read but reported as unplayable."
        case .invalidDuration:
            return "The file reported no usable duration."
        case .sourceVanished:
            return "The file disappeared before it could be copied."
        case .duplicate:
            return "This file is already in your library."
        case .diskFull:
            return "There was not enough free space to finish the import."
        case .sourceChanged:
            return "The file was modified while it was being read."
        case .cancelled:
            return "The import was cancelled."
        }
    }

    // MARK: - LocalizedError

    /// `detail` is the message that actually explains the failure; `title` is
    /// the short label the report rows show.
    var errorDescription: String? { detail }

    /// Classifies a thrown error, so callers do not have to.
    static func classify(_ error: Error) -> ImportFailure {
        if let failure = error as? ImportFailure { return failure }

        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return .unsupportedCodec
        }

        switch nsError.code {
        case NSFileReadNoPermissionError:
            return .noPermission
        case NSFileReadNoSuchFileError:
            return .sourceVanished
        case NSFileWriteOutOfSpaceError:
            return .diskFull
        case NSFileWriteFileExistsError:
            return .duplicate
        case NSFileReadCorruptFileError, NSFileReadInvalidFileNameError:
            return .unsupportedCodec
        case NSFileReadUnknownError:
            return .unsupportedCodec
        default:
            return .unsupportedCodec
        }
    }
}

/// One refused file. `name` is the original basename, which is what the user
/// recognises — not the UUID-named file we would have written.
struct FailedImport: Hashable, Identifiable {
    var id: UUID { failureID }
    let name: String
    let failure: ImportFailure
    let underlying: String?
    /// `true` when the user's original file is still untouched on disk. It
    /// always is: imports copy, they never move or delete the source.
    var originalIsUntouched: Bool = true

    private let failureID: UUID

    init(name: String, failure: ImportFailure, underlying: String? = nil) {
        self.name = name
        self.failure = failure
        self.underlying = underlying
        self.failureID = UUID()
    }

    static func == (lhs: FailedImport, rhs: FailedImport) -> Bool {
        lhs.failureID == rhs.failureID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(failureID)
    }
}

/// The outcome of one import batch, or of a resumed journal.
///
/// Published rather than printed, because the absence of this is the reason the
/// original problem was misdiagnosed as a permissions issue.
struct ImportReport: Identifiable {
    let id: UUID
    var succeeded: [AudioFile]
    var failed: [FailedImport]

    init(
        id: UUID = UUID(),
        succeeded: [AudioFile] = [],
        failed: [FailedImport] = []
    ) {
        self.id = id
        self.succeeded = succeeded
        self.failed = failed
    }

    var isEmpty: Bool { succeeded.isEmpty && failed.isEmpty }
    var hasFailures: Bool { !failed.isEmpty }

    var summary: String {
        switch (succeeded.count, failed.count) {
        case (0, 0): return "Nothing imported."
        case (1, 0): return "Imported 1 song."
        case (let ok, 0): return "Imported \(ok) songs."
        case (0, 1): return "Could not import 1 file."
        case (0, let bad): return "Could not import \(bad) files."
        case (1, let bad): return "Imported 1 song, could not import \(bad) files."
        case (let ok, let bad): return "Imported \(ok) songs, could not import \(bad) files."
        }
    }

    /// Failure counts grouped for display, most frequent first.
    var groupedFailures: [(failure: ImportFailure, names: [String])] {
        Dictionary(grouping: failed, by: \.failure)
            .map { (failure: $0.key, names: $0.value.map(\.name)) }
            .sorted { $0.names.count > $1.names.count }
    }

    mutating func merge(_ other: ImportReport) {
        succeeded.append(contentsOf: other.succeeded)
        failed.append(contentsOf: other.failed)
    }
}

/// Live import activity.
///
/// Replaces `AudioManager.isImporting`, a single `Bool` that the *first* of N
/// concurrent imports to finish would clear — so a 50-file batch reported itself
/// done after the first file.
struct ImportProgress: Equatable {
    var active: Int = 0
    var total: Int = 0

    var isRunning: Bool { active > 0 }

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(total - active) / Double(total)
    }

    var label: String {
        guard total > 0 else { return "" }
        let done = total - active
        return done == total ? "Imported \(total)" : "Importing \(done) of \(total)"
    }
}
