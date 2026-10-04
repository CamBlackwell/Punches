import Foundation

struct AudioFile: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let dateAdded: Date
    let audioDuration: Float
    var artworkImageName: String?
    var title: String

    // MARK: Metadata
    //
    // Read from the file's own tags by `AudioMetadataReader` and carried through
    // to the UI. Every one is optional because a file need not be tagged, and
    // `nil` has to stay distinguishable from "" — an empty artist line is a
    // different thing from a file that was never asked.

    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var comment: String?

    var fileURL: URL {
        AudioManager.fileDirectory.appendingPathComponent(fileName)
    }

    /// The extension-free name. Both initialisers and the decoder use this, so a
    /// track's displayed title no longer depends on which code path created it.
    ///
    /// Only ever the *fallback*. A tagged file's title comes from its tags, and
    /// the filename is a worse answer than the user already wrote.
    private static func title(from fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    init(fileName: String, audioDuration: Float, artworkImageName: String? = nil) {
        self.id = UUID()
        self.fileName = fileName
        self.dateAdded = Date()
        self.audioDuration = audioDuration
        self.artworkImageName = artworkImageName
        self.title = Self.title(from: fileName)
    }

    init(
        id: UUID,
        fileName: String,
        dateAdded: Date,
        audioDuration: Float,
        artworkImageName: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        comment: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.dateAdded = dateAdded
        self.audioDuration = audioDuration
        self.artworkImageName = artworkImageName
        self.title = title ?? Self.title(from: fileName)
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, dateAdded, audioDuration, artworkImageName, title
        case artist, album, albumArtist, genre, year
        case trackNumber, trackTotal, discNumber, discTotal, comment
    }

    /// Decoded field by field, with a default for every key that may be absent.
    ///
    /// The library index is no longer stored as JSON — `LibraryStore` keeps one
    /// row per track — but the old blobs are still read during migration, and a
    /// synthesized decoder turns any added or retyped key into a total decode
    /// failure. See `Playlist.init(from:)` for the incident that motivated this.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fileName = try container.decode(String.self, forKey: .fileName)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.fileName = fileName
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        audioDuration = try container.decodeIfPresent(Float.self, forKey: .audioDuration) ?? 0
        artworkImageName = try container.decodeIfPresent(String.self, forKey: .artworkImageName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? Self.title(from: fileName)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        trackTotal = try container.decodeIfPresent(Int.self, forKey: .trackTotal)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        discTotal = try container.decodeIfPresent(Int.self, forKey: .discTotal)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
    }

    /// The single line to show under the title.
    ///
    /// Album artist is the fallback because single-artist files are tagged
    /// inconsistently between the two fields; see `AudioMetadata.bestArtist`.
    var subtitle: String? {
        let parts = [
            bestArtistLabel,
            album,
            year.map(String.init),
        ].compactMap { $0 }.filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private var bestArtistLabel: String? {
        if let artist, !artist.isEmpty { return artist }
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        return nil
    }
}

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var audioFileIDs: [UUID]
    let dateAdded: Date
    var artworkImageName: String?
    /// Albums are playlists with a cover-first presentation: same membership,
    /// same ordering, same mutations, surfaced on their own page.
    var isAlbum: Bool
    /// True once the user picks a cover by hand. While false, the cover shown is
    /// derived from the first member song that has artwork.
    var coverIsManual: Bool
    var artist: String?
    /// Where the user put this collection on its page, ascending. `nil` means the
    /// page was never arranged, which is different from "arranged and currently
    /// first" — so it is nullable rather than a defaulted zero. Written only by
    /// `PlaylistService.moveCollection`, and only for the page it was given, so
    /// arranging albums leaves the Playlists page alone.
    var sortOrder: Double?
    /// Set when this row is a projection of a group of file tags rather than a
    /// collection the user built. `nil` for every hand-made playlist or album.
    ///
    /// Nullable for the same reason as `sortOrder`: "derived from the library's
    /// tags" and "the user made this" are opposites, and the answer decides
    /// whether a projection is allowed to rewrite the row.
    var tagKey: String?

    init(
        name: String,
        artworkImageName: String? = nil,
        isAlbum: Bool = false,
        artist: String? = nil,
        tagKey: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.audioFileIDs = []
        self.dateAdded = Date()
        self.artworkImageName = artworkImageName
        self.isAlbum = isAlbum
        self.coverIsManual = artworkImageName != nil
        self.artist = artist
        self.sortOrder = nil
        self.tagKey = tagKey
    }

    /// Full designated initialiser, preserving identity and membership.
    ///
    /// Declaring the initialisers above suppresses Swift's synthesised memberwise
    /// one, so loading a playlist back out of the store — which must round-trip
    /// `id`, `dateAdded` and the ordered membership exactly — needs this spelled
    /// out.
    ///
    /// `sortOrder` and `tagKey` have no defaults on purpose. There is one caller
    /// (`PlaylistRecord.playlist`), and a defaulted added column is exactly how a
    /// write path ends up silently dropping a value the column exists to hold.
    init(
        id: UUID,
        name: String,
        audioFileIDs: [UUID],
        dateAdded: Date,
        artworkImageName: String?,
        isAlbum: Bool,
        coverIsManual: Bool,
        artist: String?,
        sortOrder: Double?,
        tagKey: String?
    ) {
        self.id = id
        self.name = name
        self.audioFileIDs = audioFileIDs
        self.dateAdded = dateAdded
        self.artworkImageName = artworkImageName
        self.isAlbum = isAlbum
        self.coverIsManual = coverIsManual
        self.artist = artist
        self.sortOrder = sortOrder
        self.tagKey = tagKey
    }

    enum CodingKeys: String, CodingKey {
        case id, name, audioFileIDs, dateAdded, artworkImageName
        case isAlbum, coverIsManual, artist, sortOrder, tagKey
    }

    /// Decoded field by field so that a blob written before a field existed
    /// still loads. The synthesized decoder requires every non-optional key to
    /// be present, and one missing key throws away the whole `savedPlaylists`
    /// array — which routes `loadOrCreateMasterPlaylist` into its recovery
    /// branch and deletes every user playlist. New keys must use
    /// `decodeIfPresent` with a default for the same reason.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        audioFileIDs = try container.decodeIfPresent([UUID].self, forKey: .audioFileIDs) ?? []
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        artworkImageName = try container.decodeIfPresent(String.self, forKey: .artworkImageName)
        isAlbum = try container.decodeIfPresent(Bool.self, forKey: .isAlbum) ?? false
        coverIsManual = try container.decodeIfPresent(Bool.self, forKey: .coverIsManual) ?? false
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        // Nullable, so `decodeIfPresent` with no default — the same shape as
        // `artist` above. A *required* key here would make a blob written before
        // these columns existed fail to decode, and that is the incident this
        // initialiser exists to prevent.
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder)
        tagKey = try container.decodeIfPresent(String.self, forKey: .tagKey)
    }
}

enum LibraryFilter: Hashable {
    case songs
    case playlists
    case albums
    case player
}

enum LibraryItem: Identifiable {
    case song(AudioFile)
    case playlist(Playlist)
    
    var id: UUID {
        switch self {
        case .song(let s): return s.id
        case .playlist(let p): return p.id
        }
    }
    
    var dateAdded: Date {
        switch self {
        case .song(let s): return s.dateAdded
        case .playlist(let p): return p.dateAdded
        }
    }
}


enum ArtworkTarget: Identifiable {
    case audioFile(AudioFile)
    case playlist(Playlist)
    case multipleFiles(Set<UUID>)
    
    var id: String {
        switch self {
        case .audioFile(let file):
            return "file-\(file.id)"
        case .playlist(let playlist):
            return "playlist-\(playlist.id)"
        case .multipleFiles(let ids):
            return "multiple-\(ids.sorted().map { $0.uuidString }.joined())"
        }
    }
}

