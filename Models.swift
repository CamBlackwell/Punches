import Foundation

struct AudioFile: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let dateAdded: Date
    let audioDuration: Float
    var artworkImageName: String?
    var title: String
    
    var fileURL: URL {
        AudioManager.fileDirectory.appendingPathComponent(fileName)
    }
    
    /// The extension-free name. Both initialisers and the decoder use this, so a
    /// track's displayed title no longer depends on which code path created it.
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
    
    init(id: UUID, fileName: String, dateAdded: Date, audioDuration: Float, artworkImageName: String? = nil, title: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.dateAdded = dateAdded
        self.audioDuration = audioDuration
        self.artworkImageName = artworkImageName
        self.title = title ?? Self.title(from: fileName)
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, dateAdded, audioDuration, artworkImageName, title
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

    init(name: String, artworkImageName: String? = nil, isAlbum: Bool = false, artist: String? = nil) {
        self.id = UUID()
        self.name = name
        self.audioFileIDs = []
        self.dateAdded = Date()
        self.artworkImageName = artworkImageName
        self.isAlbum = isAlbum
        self.coverIsManual = artworkImageName != nil
        self.artist = artist
    }

    /// Full designated initialiser, preserving identity and membership.
    ///
    /// Declaring the initialisers above suppresses Swift's synthesised memberwise
    /// one, so loading a playlist back out of the store — which must round-trip
    /// `id`, `dateAdded` and the ordered membership exactly — needs this spelled
    /// out.
    init(
        id: UUID,
        name: String,
        audioFileIDs: [UUID],
        dateAdded: Date,
        artworkImageName: String?,
        isAlbum: Bool,
        coverIsManual: Bool,
        artist: String?
    ) {
        self.id = id
        self.name = name
        self.audioFileIDs = audioFileIDs
        self.dateAdded = dateAdded
        self.artworkImageName = artworkImageName
        self.isAlbum = isAlbum
        self.coverIsManual = coverIsManual
        self.artist = artist
    }

    enum CodingKeys: String, CodingKey {
        case id, name, audioFileIDs, dateAdded, artworkImageName
        case isAlbum, coverIsManual, artist
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

