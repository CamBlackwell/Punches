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
    
    init(fileName: String, audioDuration: Float, artworkImageName: String? = nil) {
        self.id = UUID()
        self.fileName = fileName
        self.dateAdded = Date()
        self.audioDuration = audioDuration
        self.artworkImageName = artworkImageName
        self.title = (fileName as NSString).deletingPathExtension
    }
    
    init(id: UUID, fileName: String, dateAdded: Date, audioDuration: Float, artworkImageName: String? = nil, title: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.dateAdded = dateAdded
        self.audioDuration = audioDuration
        self.artworkImageName = artworkImageName
        self.title = title ?? fileName
    }
}

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var audioFileIDs: [UUID]
    let dateAdded: Date
    var artworkImageName: String?
    
    init(name: String, artworkImageName: String? = nil) {
        self.id = UUID()
        self.name = name
        self.audioFileIDs = []
        self.dateAdded = Date()
        self.artworkImageName = artworkImageName
    }
}

enum LibraryFilter: Hashable {
    case songs
    case playlists
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

