import AVFoundation
import Foundation

/// The tags and embedded artwork carried by one audio file.
///
/// Deliberately a value type with no reference to the store, the manager or the
/// file system: it is the *answer* to "what does this file say about itself?",
/// and everything downstream — the import pipeline, the backfill sweep, a future
/// tag editor — consumes the same answer.
struct AudioMetadata: Equatable {

    // MARK: Descriptive

    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?

    /// Release year, from the tag that carries one (`TDRC`, `TYER`, or a
    /// `creationDate` that AVFoundation has already normalised into text).
    var year: Int?

    /// Track and disc positions, and their totals. `trackTotal` is `nil` for a
    /// bare `3` with no `3/12` — a distinction worth keeping, because the
    /// "3 of 12" label has to say something different from "3".
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?

    var comment: String?

    /// The embedded cover image, still encoded as it was in the file.
    ///
    /// Kept as `Data` rather than a decoded image so that decoding happens once,
    /// at the point where a `UIImage` is actually needed — and so a file is never
    /// held open or a large buffer decoded for a library row that may never be
    /// drawn.
    var artworkData: Data?

    // MARK: Audio properties

    /// From the audio stream rather than a tag. Always present when the file
    /// opened at all; carried here so one read of a file yields everything the
    /// library stores about it.
    var sampleRate: Double?
    var channelCount: Int?

    /// True when nothing at all was found — no tags and no properties. Lets the
    /// backfill sweep record "we looked" without conflating that with a failure.
    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil
            && genre == nil && year == nil && trackNumber == nil && trackTotal == nil
            && discNumber == nil && discTotal == nil && comment == nil
            && artworkData == nil
    }

    /// `artist`, or `albumArtist`, or nil — the best single line to show under a
    /// title. Album artists are the fallback because single-artist files tag
    /// inconsistently between the two.
    var bestArtist: String? {
        if let artist, !artist.isEmpty { return artist }
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        return nil
    }
}

/// Reads tags out of an audio file.
///
/// ## Never throws
///
/// A missing tag is not an error, and neither is an unreadable one. Every entry
/// point returns an empty or partial `AudioMetadata` rather than throwing,
/// because tags are an *addition* to an import: refusing a track because its
/// metadata is malformed would be the same class of defect as [C16](14-known-issues.md#c16-a-file-with-no-extension-could-never-be-imported-and-every-failure-was-reported-as-unsupported-format),
/// where a secondary concern was allowed to veto the primary one.
///
/// ## Why two passes
///
/// `AVMetadataItem.commonKey` standardises the easy half — title, artist, album
/// name, artwork — across containers. It has no common key for genre, year, or
/// track and disc position, because those are genuinely container-specific. So
/// the reader first takes what `commonKey` can answer, then fills the remainder
/// by matching the raw identifier (`TCON`, `TDRC`, `TRCK`, `TPOS`, `COMM`,
/// `aART`, and their UTF-16 ID3 equivalents). Both passes are first-writer-wins,
/// so the standard key always wins and the raw-identifier pass can only fill gaps.
enum AudioMetadataReader {

    /// Reads whatever `url` declares about itself.
    ///
    /// - Important: This requires `url` to carry a usable extension, because
    ///   `AVURLAsset` selects its demuxer from the filename. `LibraryImportPipeline`
    ///   guarantees that by recovering the extension from the content in `stage`;
    ///   see `AudioContainer`. A file that reaches here extension-less simply
    ///   yields empty metadata rather than an error.
    static func read(from url: URL) async -> AudioMetadata {
        var metadata = AudioMetadata()

        let items: [AVMetadataItem]
        do {
            // `\.metadata`, **not** `\.commonMetadata`. That distinction is the
            // whole reason track numbers, years, genres and comments are readable
            // at all: `commonMetadata` returns only items that AVFoundation can
            // map onto a standard key, so on a tagged MP3 it yields 5 of the 10
            // frames and silently discards `TPE2`, `TYER`, `TRCK`, `TPOS` and
            // `COMM`. `\.metadata` returns the full set. Verified on a file with
            // all ten frames present.
            items = try await AVURLAsset(url: url).load(.metadata)
        } catch {
            // No readable tag container. The file is still playable — `Probe` has
            // already established that — so this is a partial answer, not a
            // refusal.
            return metadata
        }

        for item in items {
            await apply(item, to: &metadata)
        }
        return metadata
    }

    /// Reads tags and the audio stream's properties together, so a caller that
    /// has just validated a file gets everything from one pass.
    static func read(from url: URL, probe: ProbeValues) async -> AudioMetadata {
        var metadata = await read(from: url)
        metadata.sampleRate = probe.sampleRate
        metadata.channelCount = probe.channelCount
        return metadata
    }

    // MARK: - Item mapping

    private static func apply(_ item: AVMetadataItem, to metadata: inout AudioMetadata) async {
        // `AVMetadataItem` vends its values lazily: the synchronous accessors
        // block the calling thread until they have them, which is the wrong thing
        // to do to whoever is importing a file. Loading them explicitly keeps this
        // read suspended, and loading each key independently means one unreadable
        // frame costs that frame rather than the whole file's tags.
        //
        // `stringValue` is nil for numeric and artwork items even where a string
        // rendering exists, and nil for a `----` freeform frame whose value is
        // arbitrary, so `numberValue` is the fallback.
        async let loadedString = try? item.load(.stringValue)
        async let loadedNumber = try? item.load(.numberValue)
        async let loadedData = try? item.load(.dataValue)
        let (string, number, data) = await (loadedString, loadedNumber, loadedData)

        // One rendering of the value, whatever the frame's own type was.
        let text = string ?? number.map { String($0.intValue) }

        // An explicit guard rather than `??=`: the project builds in Swift 5
        // language mode, and it keeps the "first writer wins" rule visible at each
        // site instead of buried in an operator.
        func set(_ keyPath: WritableKeyPath<AudioMetadata, String?>, _ value: String?) {
            guard let value else { return }
            if metadata[keyPath: keyPath] == nil { metadata[keyPath: keyPath] = value }
        }

        if let common = item.commonKey {
            switch common {
            case AVMetadataKey.commonKeyTitle:
                set(\.title, Self.clean(text))
            case AVMetadataKey.commonKeyArtist:
                set(\.artist, Self.clean(text))
            case AVMetadataKey.commonKeyAlbumName:
                set(\.album, Self.clean(text))
            case AVMetadataKey.commonKeyDescription:
                set(\.comment, Self.clean(text))
            case AVMetadataKey.commonKeyArtwork:
                if metadata.artworkData == nil { metadata.artworkData = data }
            case AVMetadataKey.commonKeyCreator:
                // On iTunes-tagged files the creator is frequently the album
                // artist rather than the track artist.
                set(\.albumArtist, Self.clean(text))
            default:
                break
            }
        }

        // The half `commonKey` does not standardise.
        let keys = Self.rawKeys(of: item)
        guard !keys.isEmpty else { return }

        func matches(_ field: Field) -> Bool {
            !keys.isDisjoint(with: field.names)
        }

        if matches(.genre) {
            set(\.genre, Self.clean(text))
        }
        if matches(.year), metadata.year == nil {
            metadata.year = Self.year(from: text)
        }
        if matches(.track) {
            let pair = Self.numberPair(from: text)
            if metadata.trackNumber == nil { metadata.trackNumber = pair.number }
            if metadata.trackTotal == nil { metadata.trackTotal = pair.total }
        }
        if matches(.disc) {
            let pair = Self.numberPair(from: text)
            if metadata.discNumber == nil { metadata.discNumber = pair.number }
            if metadata.discTotal == nil { metadata.discTotal = pair.total }
        }
        if matches(.comment) {
            set(\.comment, Self.clean(text))
        }
        if matches(.albumArtist) {
            set(\.albumArtist, Self.clean(text))
        }
    }

    /// The tag fields `commonKey` has no key for.
    ///
    /// `commonKey` standardises title, artist, album, description and artwork on
    /// every container. It has nothing for genre, release date, track position or
    /// album artist — which are exactly the tags a library needs to group and
    /// order anything.
    private enum Field {
        case genre, year, track, disc, comment, albumArtist

        /// Every name this field is written under, across containers.
        ///
        /// This has to be a list per field rather than a single name, because no
        /// two writers agree. Verified against real files:
        ///
        /// | | plain ID3 MP3 | Apple-tagged m4a | Vorbis comment |
        /// |---|---|---|---|
        /// | genre | `TCON` | `itsk/%A9gen` | `GENRE` |
        /// | year | `TDRC`, `TYER` | `itsk/%A9day` | `DATE` |
        /// | track | `TRCK` (`3/12`) | `itsk/trkn` | `TRACKNUMBER` |
        /// | disc | `TPOS` | `itsk/disk` | `DISCNUMBER` |
        /// | comment | `COMM` | `itsk/%A9cmt` | `COMMENT` |
        /// | album artist | `TPE2` | `itsk/aART` | `ALBUMARTIST` |
        ///
        /// The m4a column is the one that matters most: m4a is the commonest
        /// format here, and its names are neither the ID3 names nor the Vorbis
        /// ones. Matching only `TCON`/`TRCK`/`TPOS` silently drops genre, year,
        /// track number, disc number and comment from every iTunes-written file.
        var names: Set<String> {
            switch self {
            case .genre:       return ["TCON", "GNRE", "GENRE", "GEN"]
            case .year:        return ["TDRC", "TYER", "TDRL", "DATE", "DAY", "YEAR"]
            case .track:       return ["TRCK", "TRK", "TRKN", "TRACKNUMBER", "TRACK"]
            case .disc:        return ["TPOS", "TPA", "DISK", "DISCNUMBER", "DISC"]
            case .comment:     return ["COMM", "CMNT", "CMT", "COMMENT"]
            case .albumArtist: return ["TPE2", "AART", "ALBUMARTIST", "ALBUM ARTIST"]
            }
        }
    }

    /// Apple's escape for a leading `©`.
    ///
    /// The iTunes atom names begin with a copyright sign, which cannot appear in
    /// the FourCC-keyed atom table, so `AVFoundation` reports `©nam` as `%A9nam`.
    /// Stripped before comparison so one name table serves both spellings.
    private static let appleCopyrightEscape = "%A9"

    /// Every key an item might be known by: each path component of its
    /// identifiers, plus the identifiers themselves, plus those components with
    /// Apple's `%A9` prefix removed.
    ///
    /// Matching against the whole set rather than one guess is what makes this
    /// work across containers: the same tag arrives as `TRCK` from a plain ID3
    /// MP3 and as `itsk/trkn` from an iTunes-written m4a, and no single
    /// reduction of the identifier yields both.
    ///
    /// Only a name in some `Field.names` can match, so an opaque identifier -- a
    /// UUID, or Apple's `----:com.apple.iTunes:...` freeform keys -- cannot
    /// shadow a field it merely happens to contain. Note that `item.key` is
    /// useless here for these atoms: for `itsk/%A9nam` it is the FourCC `©nam` as
    /// an `Int`, so it is not a `String` at all.
    private static func rawKeys(of item: AVMetadataItem) -> Set<String> {
        let identifiers = [
            item.identifier?.rawValue,
            item.key as? String,
        ].compactMap { $0 }.filter { !$0.isEmpty }

        var keys: Set<String> = []
        for identifier in identifiers {
            let upper = identifier.uppercased()
            keys.insert(upper)
            for component in identifier.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == ":" }) {
                let name = String(component).uppercased()
                keys.insert(name)
                if name.hasPrefix(appleCopyrightEscape) {
                    keys.insert(String(name.dropFirst(appleCopyrightEscape.count)))
                }
            }
        }
        return keys
    }

    // MARK: - Value parsing

    /// Collapses whitespace and rejects values that are only separators.
    ///
    /// ID3 padding fields routinely decode to `" "`, `"-"` or `"\0"`, which would
    /// otherwise surface as a blank artist line in the UI.
    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.contains(where: { !$0.isPunctuation && !$0.isWhitespace }) else {
            return nil
        }
        return trimmed
    }

    /// `1994` from `TDRC`, `1994-06-21`, or `1994-06-21T00:00:00Z`.
    ///
    /// Only the leading four digits are taken, and only when they look like a
    /// year — an `XD3` comment or a track count must not become a year.
    private static func year(from value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber }
        guard digits.count >= 3 else { return nil }
        guard let year = Int(digits.prefix(4)) else { return nil }
        return (1900...2999).contains(year) ? year : nil
    }

    /// Splits `3` or `3/12` into its two halves.
    ///
    /// Tolerates the byte-swapped shapes some taggers write: `3/0` is track 3 of
    /// an unknown total, not track 3 of zero.
    private static func numberPair(from value: String?) -> (number: Int?, total: Int?) {
        guard let value else { return (nil, nil) }
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let number = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return (nil, nil)
        }
        guard parts.count == 2,
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              total > 0 else {
            return (number, nil)
        }
        return (number, total)
    }
}

/// The audio-stream half of a read, carried separately so `AudioMetadataReader`
/// does not have to depend on the pipeline's private `Probe` type.
struct ProbeValues {
    var sampleRate: Double
    var channelCount: Int
}
