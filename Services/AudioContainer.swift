import Foundation

/// Identifies an audio file's container from its leading bytes.
///
/// ## Why this exists
///
/// `AVURLAsset` cannot open a file that has no extension — it fails with
/// `AVError.fileFormatNotRecognized` — while `AVAudioFile` and `AVAudioPlayer`
/// both sniff the content and open it happily. The import pipeline used to
/// validate with `AVURLAsset` after renaming the staged copy to a job UUID,
/// so a source URL with no `pathExtension` produced a bare UUID filename and
/// *every* file from that source was rejected as "Unsupported format".
///
/// Knowing the container from the bytes also means the stored file gets a real
/// extension, which matters beyond validation: `urlForSharing` hands the live
/// file to other apps, and a recipient that keys off the extension rejects it.
///
/// ## What this is not
///
/// This identifies containers. It does **not** decide whether iOS can decode
/// them — `OggS` is recognised as `ogg` and reported accurately, but iOS still
/// cannot play it. `AVAudioFile` remains the authority on playability.
enum AudioContainer {

    /// The extension for the container at `url`, or `nil` if the leading bytes
    /// match nothing known.
    ///
    /// Reads only the first bytes needed, via a single small read.
    static func fileExtension(ofContentsAt url: URL) -> String? {
        guard let header = readHeader(at: url) else { return nil }
        return fileExtension(ofHeader: header)
    }

    /// Exposed separately so the header parsing is testable without a file.
    static func fileExtension(ofHeader header: Data) -> String? {
        func ascii(_ range: Range<Int>) -> String {
            guard range.upperBound <= header.count else { return "" }
            return String(decoding: header[range], as: UTF8.self)
        }
        func byte(_ index: Int) -> UInt8? {
            index < header.count ? header[header.startIndex + index] : nil
        }

        // RIFF….WAVE — WAVE, and the WebM family, which share the first four
        // bytes. The discriminator is at offset 8.
        if ascii(0..<4) == "RIFF" { return ascii(8..<12) == "WAVE" ? "wav" : nil }

        // FORM….AIFF / AIFC
        if ascii(0..<4) == "FORM" {
            switch ascii(8..<12) {
            case "AIFF", "AIFC": return "aiff"
            default: return nil
            }
        }

        if ascii(0..<4) == "caff" { return "caf" }
        if ascii(0..<4) == "fLaC" { return "flac" }

        // ISO base media (MP4 family): a 4-byte box size then the `ftyp` type.
        if ascii(4..<8) == "ftyp" {
            switch ascii(8..<12) {
            case "M4A ": return "m4a"
            case "M4B ": return "m4b"
            // `isom`, `mp42`, `M4V `… all carry audio-only or AAC-in-MP4 content
            // that AVFoundation opens as an MPEG-4 asset.
            case "M4V ", "M4P ": return "m4v"
            default: return "m4a"
            }
        }

        // ID3v2 tag, or a bare MPEG audio frame sync.
        if ascii(0..<3) == "ID3" { return "mp3" }
        if let first = byte(0), let second = byte(1),
           first == 0xFF, second & 0xE0 == 0xE0 {
            return "mp3"
        }

        // AMR — narrowband, but identified so the refusal is specific.
        if ascii(0..<5) == "#!AMR" { return "amr" }

        // Recognised, and not decodable by iOS. Returned rather than nil so the
        // report can name the format instead of saying "unsupported" vaguely.
        if ascii(0..<4) == "OggS" { return "ogg" }
        if byte(0) == 0x30, byte(1) == 0x26, byte(2) == 0xB2, byte(3) == 0x75 { return "wma" }
        if ascii(0..<4) == "MAC " { return "ape" }
        if ascii(0..<8) == "TTA1" || ascii(0..<4) == "DSD " { return "dff" }

        return nil
    }

    /// The extensions iOS can actually decode, for the "these will not work"
    /// note in the import report and any pre-flight advice.
    ///
    /// Deliberately not the same set as `LibraryEnvironment.audioExtensions`,
    /// which is the legacy-layout migration's much narrower list and is about
    /// *moving* files, not decoding them.
    static let decodableExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "alac", "caf", "wav", "aiff", "aif", "aifc",
        "flac", "mp4", "amr", "m4v",
    ]

    /// Whether iOS is expected to decode this container.
    static func isDecodable(_ ext: String) -> Bool {
        decodableExtensions.contains(ext.lowercased())
    }

    private static func readHeader(at url: URL, length: Int = 16) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: length)) ?? Data()
    }
}
