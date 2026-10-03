import AVFoundation
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
    /// The container is one iOS has no decoder for (OGG, WMA, APE, …).
    case unsupportedContainer
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
    /// The library database refused the write. Not a problem with the file.
    case libraryUnavailable
    /// The file could not be copied or coordinated into `Staging/`.
    case copyFailed
    /// Something failed that has no mapping. The underlying error is the report.
    case unknown
    case cancelled

    var title: String {
        switch self {
        case .noPermission: return "No permission"
        case .cloudNotDownloaded: return "Still downloading"
        case .unsupportedCodec: return "Could not be decoded"
        case .unsupportedContainer: return "Unsupported format"
        case .drmProtected: return "Protected file"
        case .notPlayable: return "Not playable"
        case .invalidDuration: return "Damaged file"
        case .sourceVanished: return "File no longer there"
        case .duplicate: return "Already added"
        case .diskFull: return "No space left"
        case .sourceChanged: return "File changed while copying"
        case .libraryUnavailable: return "Library could not save"
        case .copyFailed: return "Could not be copied"
        case .unknown: return "Import failed"
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
        case .unsupportedContainer:
            return "iOS has no decoder for this kind of file. Try an MP3, M4A, AAC, ALAC, WAV, AIFF, CAF or FLAC."
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
        case .libraryUnavailable:
            return "The library database could not be written. This is not a problem with the file."
        case .copyFailed:
            return "The file could not be copied into the library."
        case .unknown:
            return "Something went wrong that has not been identified yet."
        case .cancelled:
            return "The import was cancelled."
        }
    }

    // MARK: - LocalizedError

    /// `detail` is the message that actually explains the failure; `title` is
    /// the short label the report rows show.
    var errorDescription: String? { detail }

    /// Classifies a thrown error, so callers do not have to.
    ///
    /// ## Why this used to be wrong
    ///
    /// Every error whose domain was not `NSCocoaErrorDomain` was reported as
    /// `unsupportedCodec`, as was every unrecognised Cocoa code. A SQLite
    /// failure, a `NSFileCoordinator` failure, a POSIX `errno` and a Swift
    /// decoding error were therefore all reported to the user as
    /// *"Unsupported format"* — telling them their file was at fault when the
    /// fault was ours. That is the exact misdiagnosis this enum was written to
    /// end, and it is what made the extension-less import bug
    /// ([C16](14-known-issues.md#c16-a-file-with-no-extension-could-never-be-imported-and-every-failure-was-reported-as-unsupported-format))
    /// so hard to find: the one symptom the app could show was a lie.
    ///
    /// `unsupportedCodec` is now only ever returned on positive evidence that
    /// the decoder refused the bytes. Anything unrecognised is `.unknown`, which
    /// keeps `FailedImport.underlying` — the actual error — as the thing the
    /// user and the log are shown.
    static func classify(_ error: Error) -> ImportFailure {
        if let failure = error as? ImportFailure { return failure }
        if error is LibraryStoreError { return .libraryUnavailable }

        let nsError = error as NSError

        // A codec verdict may only come from the framework that does the decoding.
        if nsError.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: nsError.code) {
            case .fileFormatNotRecognized, .decodeFailed,
                 .fileFailedToParse, .invalidSourceMedia:
                return .unsupportedCodec
            case .contentIsProtected, .contentIsNotAuthorized,
                 .applicationIsNotAuthorized:
                return .drmProtected
            case .diskFull:
                return .diskFull
            default:
                return .unknown
            }
        }

        // `NSFileCoordinatorErrorDomain` is not surfaced to Swift, so it is matched by
        // value. `NSFileCoordinator` is what `stage` reads and writes through.
        if nsError.domain == "NSFileCoordinatorErrorDomain" {
            return .copyFailed
        }

        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOENT): return .sourceVanished
            case Int(EACCES), Int(EPERM): return .noPermission
            case Int(ENOSPC): return .diskFull
            default: return .unknown
            }
        }

        guard nsError.domain == NSCocoaErrorDomain else { return .unknown }

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
        default:
            return .unknown
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
    /// Failures grouped by cause, most frequent first.
    ///
    /// Carries the whole `FailedImport` rather than just its name, because the
    /// `underlying` reason is what makes a group actionable — "Unsupported
    /// format" alone cannot distinguish "this OGG has no iOS decoder" from "the
    /// copy failed" from "the database rejected the write".
    var groupedFailures: [(failure: ImportFailure, failures: [FailedImport])] {
        Dictionary(grouping: failed, by: \.failure)
            .map { (failure: $0.key, failures: $0.value) }
            .sorted { $0.failures.count > $1.failures.count }
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
