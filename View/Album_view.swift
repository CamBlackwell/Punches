import SwiftUI
import PhotosUI

// MARK: - Cover

/// Square album cover, or a themed placeholder when the album has none.
/// The cover shown is either one the user picked by hand or, failing that, the
/// artwork of the first member song that has some.
struct AlbumCoverThumbnail: View {
    let cover: UIImage?
    @EnvironmentObject var theme: ThemeManager
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            theme.accentColor.opacity(0.12)

            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.accentColor.opacity(0.8))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Albums Grid

struct AlbumsListView: View {
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var isScrolledDown: Bool
    let albums: [Playlist]
    /// Whether `albums` is a search result rather than the whole Albums page.
    ///
    /// Passed in rather than derived, because only `ContentView` knows about
    /// `searchText`, and the difference decides whether reordering is offered at
    /// all — see `reorderableAlbums`.
    var isFiltered: Bool = false

    @State private var albumBeingAddedTo: Playlist?
    @State private var albumBeingRenamed: Playlist?
    @State private var showingRenameAlbumAlert = false
    @State private var renamingAlbumName = ""
    @State private var isReorderMode = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    /// The page `.onMove`'s indices refer to.
    ///
    /// `nil` while a search is active, which disables reordering. A `LazyVGrid`
    /// has no `.onMove`, so reordering swaps the grid for a `List` — and `.onMove`
    /// indexes whatever array it is attached to, which is the *rendered* one. If
    /// that were `filteredAlbums`, dragging the third of five search results
    /// would renumber three unrelated positions against the unfiltered page. This
    /// is C5's lesson applied one level up: the list the user is looking at and
    /// the list being renumbered have to be the same list, or be no list at all.
    private var reorderableAlbums: [Playlist]? {
        isFiltered ? nil : albums
    }

    var body: some View {
        Group {
            if isReorderMode, let reorderableAlbums {
                reorderList(reorderableAlbums)
            } else {
                grid
            }
        }
        .background(Color.clear)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, newOffset in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62, blendDuration: 0.15)) {
                isScrolledDown = newOffset > 60
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isReorderMode {
                    Button("Done") { isReorderMode = false }
                        .foregroundStyle(theme.accentColor)
                } else {
                    Button {
                        isReorderMode = true
                    } label: {
                        Label("Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(reorderableAlbums == nil)
                }
            }
        }
        .sheet(item: $albumBeingAddedTo) { album in
            AddSongsToAlbumSheet(album: album, audioManager: audioManager)
        }
        .alert("Rename Album", isPresented: $showingRenameAlbumAlert) {
            TextField("Album Name", text: $renamingAlbumName)
            Button("Cancel", role: .cancel) {
                albumBeingRenamed = nil
            }
            Button("Rename") {
                if let album = albumBeingRenamed, !renamingAlbumName.isEmpty {
                    audioManager.renamePlaylist(album, to: renamingAlbumName)
                }
                albumBeingRenamed = nil
                renamingAlbumName = ""
            }
        } message: {
            if let album = albumBeingRenamed {
                Text("Enter a new name for '\(album.name)'")
            }
        }
    }

    // MARK: - The two layouts

    private var grid: some View {
        // One pass over the library for the whole grid, rather than a resolve
        // per cell.
        let songsByAlbum = audioManager.songsByPlaylistID(for: albums)

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    let songs = songsByAlbum[album.id] ?? []

                    NavigationLink {
                        AlbumDetailView(
                            albumID: album.id,
                            audioManager: audioManager,
                            navigateToPlayer: $navigateToPlayer,
                            selectedAudioFile: $selectedAudioFile,
                            artworkTarget: $artworkTarget,
                            showingRenameAlert: $showingRenameAlert,
                            renamingAudioFile: $renamingAudioFile,
                            newFileName: $newFileName,
                            isScrolledDown: $isScrolledDown
                        )
                    } label: {
                        AlbumGridCell(album: album, songs: songs, audioManager: audioManager)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { albumContextMenu(album) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 35)
        }
    }

    /// Reorder mode.
    ///
    /// A `List`, not the grid: `LazyVGrid` has no `.onMove`, and iOS offers no way
    /// to drag a grid cell to a new index. Swapping layouts is the same approach
    /// `AlbumDetailView` already takes for its songs, and it keeps the
    /// arrangement on screen while it is being made instead of hiding it behind a
    /// second screen.
    ///
    /// Rows are non-navigating in this mode — the drag handles are the point, and
    /// a `NavigationLink` row in an active `List` competes with them for the same
    /// gesture.
    private func reorderList(_ page: [Playlist]) -> some View {
        let songsByAlbum = audioManager.songsByPlaylistID(for: page)

        return List {
            ForEach(page) { album in
                let songs = songsByAlbum[album.id] ?? []

                HStack(spacing: 12) {
                    AlbumCoverThumbnail(cover: albumCover(album, songs: songs))
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textColor)
                            .lineLimit(1)
                        Text(album.artist ?? "\(songs.count) songs")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryTextColor)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                // `page` is the array this `ForEach` renders, so the indices are
                // positions in it. Passing it through is what makes that true —
                // see `reorderableAlbums`.
                audioManager.moveCollection(in: page, from: source, to: destination)
            }

            Color.clear.frame(height: 35)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    @ViewBuilder
    private func albumContextMenu(_ album: Playlist) -> some View {
        Button(
            album.coverIsManual ? "Change Cover" : "Set Cover",
            systemImage: "photo"
        ) {
            artworkTarget = .playlist(album)
        }

        if album.coverIsManual {
            Button(
                "Remove Cover",
                systemImage: "photo.badge.minus",
                role: .destructive
            ) {
                audioManager.removeArtwork(from: album)
            }
        }

        Button("Add Songs", systemImage: "plus") {
            albumBeingAddedTo = album
        }

        Button("Rename", systemImage: "pencil.and.outline") {
            albumBeingRenamed = album
            renamingAlbumName = album.name
            showingRenameAlbumAlert = true
        }

        Button(role: .destructive) {
            audioManager.deletePlaylist(album)
        } label: {
            Label("Delete Album", systemImage: "trash")
        }
    }

    private func albumCover(_ album: Playlist, songs: [AudioFile]) -> UIImage? {
        guard let name = audioManager.coverName(for: album, songs: songs) else { return nil }
        return audioManager.artworkService.loadArtworkImage(name)
    }
}

// MARK: - Albums Grid Cell

struct AlbumGridCell: View {
    let album: Playlist
    let songs: [AudioFile]
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager

    private var cover: UIImage? {
        guard let name = audioManager.coverName(for: album, songs: songs) else { return nil }
        return audioManager.artworkService.loadArtworkImage(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumCoverThumbnail(cover: cover)

            Text(album.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(album.artist ?? "\(songs.count) songs")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Album Detail

struct AlbumDetailView: View {
    let albumID: UUID
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var isScrolledDown: Bool

    @State private var isReorderMode = false
    @State private var isMultiSelectMode = false
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var showingShareSheet = false
    @State private var shareURLs: [URL] = []
    @State private var showingBatchPlaylistMenu = false
    @State private var showingBatchDeleteAlert = false
    @State private var showingBatchRemoveAlert = false
    @State private var showingAddSongsSheet = false
    @State private var showingRenameAlbumAlert = false
    @State private var renamingAlbumName = ""
    @State private var showingArtistAlert = false
    @State private var artistName = ""

    /// Resolved from the manager rather than held as a value: the grid hands
    /// down a snapshot, so a rename or a cover change would not otherwise be
    /// reflected in the header.
    private var album: Playlist? {
        audioManager.playlists.first { $0.id == albumID }
    }

    private var albumSongs: [AudioFile] {
        guard let album else { return [] }
        return audioManager.getAudioFiles(for: album)
    }

    private var cover: UIImage? {
        guard let album,
              let name = audioManager.coverName(for: album, songs: albumSongs)
        else { return nil }
        return audioManager.artworkService.loadArtworkImage(name)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(theme.backgroundColor)
                .ignoresSafeArea()

            List {
                if let album {
                    albumHeader(album, songs: albumSongs, cover: cover)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if albumSongs.isEmpty {
                    Text("This album has no songs yet")
                        .font(.headline)
                        .foregroundStyle(theme.secondaryTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(albumSongs.enumerated()), id: \.element.id) { row in
                        let audioFile = row.element
                        if let album {
                            PlaylistAudioFileButton(
                                audioFile: audioFile,
                                playlist: album,
                                audioManager: audioManager,
                                navigateToPlayer: $navigateToPlayer,
                                selectedAudioFile: $selectedAudioFile,
                                showingRenameAlert: $showingRenameAlert,
                                renamingAudioFile: $renamingAudioFile,
                                newFileName: $newFileName,
                                context: albumSongs,
                                isReorderMode: isReorderMode,
                                showingShareSheet: $showingShareSheet,
                                shareURLs: $shareURLs,
                                artworkTarget: $artworkTarget,
                                isMultiSelectMode: isMultiSelectMode,
                                selectedFileIDs: $selectedFileIDs,
                                showingBatchPlaylistMenu: $showingBatchPlaylistMenu,
                                showingBatchDeleteAlert: $showingBatchDeleteAlert,
                                showingBatchRemoveAlert: $showingBatchRemoveAlert,
                                trackNumber: row.offset + 1
                            )
                            .swipeActions {
                                if !isReorderMode && !isMultiSelectMode {
                                    Button(role: .destructive) {
                                        audioManager.removeAudioFile(audioFile, from: album)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .onMove { source, destination in
                        guard let album else { return }
                        audioManager.reorderPlaylistSongs(in: album, from: source, to: destination)
                    }
                }

                Color.clear.frame(height: 35).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.90),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newOffset in
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62, blendDuration: 0.15)) {
                    isScrolledDown = newOffset > 60
                }
            }
            .environment(\.editMode, isReorderMode ? .constant(.active) : .constant(.inactive))

            if audioManager.currentlyPlayingID != nil && !isMultiSelectMode {
                MiniPlayerBar(
                    audioManager: audioManager,
                    navigateToPlayer: $navigateToPlayer,
                    selectedAudioFile: $selectedAudioFile
                )
            }
        }
        .background(Color.clear)
        // The header carries the album name, so the bar keeps only the back
        // button. The title is still announced to VoiceOver from the header.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    if isMultiSelectMode {
                        Button {
                            if selectedFileIDs.count == albumSongs.count {
                                selectedFileIDs.removeAll()
                            } else {
                                selectedFileIDs = Set(albumSongs.map { $0.id })
                            }
                        } label: {
                            Text("All")
                                .foregroundStyle(theme.accentColor)
                        }
                    }

                    if isMultiSelectMode || isReorderMode {
                        Button("Done") {
                            if isMultiSelectMode {
                                isMultiSelectMode = false
                                selectedFileIDs.removeAll()
                            } else {
                                isReorderMode = false
                            }
                        }
                        .foregroundStyle(theme.accentColor)
                    } else {
                        Menu {
                            Button {
                                isMultiSelectMode = true
                                selectedFileIDs.removeAll()
                            } label: {
                                Label("Select Multiple", systemImage: "checkmark.circle")
                            }
                            Button {
                                isReorderMode.toggle()
                            } label: {
                                Label("Reorder", systemImage: "arrow.up.arrow.down")
                            }
                            Button {
                                showingAddSongsSheet = true
                            } label: {
                                Label("Add Songs", systemImage: "plus")
                            }
                            if let album {
                                Button {
                                    artworkTarget = .playlist(album)
                                } label: {
                                    Label(
                                        album.coverIsManual ? "Change Cover" : "Set Cover",
                                        systemImage: "photo"
                                    )
                                }
                                if album.coverIsManual {
                                    Button(role: .destructive) {
                                        audioManager.removeArtwork(from: album)
                                    } label: {
                                        Label("Remove Cover", systemImage: "photo.badge.minus")
                                    }
                                }
                                Button {
                                    renamingAlbumName = album.name
                                    showingRenameAlbumAlert = true
                                } label: {
                                    Label("Rename Album", systemImage: "pencil.and.outline")
                                }
                                Button {
                                    artistName = album.artist ?? ""
                                    showingArtistAlert = true
                                } label: {
                                    Label(
                                        album.artist == nil ? "Add Artist" : "Edit Artist",
                                        systemImage: "person.text.rectangle"
                                    )
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSongsSheet) {
            if let album {
                AddSongsToAlbumSheet(album: album, audioManager: audioManager)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: shareURLs)
        }
        .alert("Rename Album", isPresented: $showingRenameAlbumAlert) {
            TextField("Album Name", text: $renamingAlbumName)
            Button("Cancel", role: .cancel) {
                renamingAlbumName = ""
            }
            Button("Rename") {
                if let album, !renamingAlbumName.isEmpty {
                    audioManager.renamePlaylist(album, to: renamingAlbumName)
                }
                renamingAlbumName = ""
            }
        }
        .alert("Album Artist", isPresented: $showingArtistAlert) {
            TextField("Artist Name", text: $artistName)
            Button("Cancel", role: .cancel) {
                artistName = ""
            }
            Button("Save") {
                if let album {
                    audioManager.setArtist(artistName, for: album)
                }
                artistName = ""
            }
        } message: {
            Text("Shown as the subtitle under the album title.")
        }
        .confirmationDialog("Add to Playlist", isPresented: $showingBatchPlaylistMenu) {
            if let album {
                ForEach(transferTargets(excluding: album)) { target in
                    Button(target.name) {
                        audioManager.addAudioFiles(selectedSongsInAlbumOrder, to: target)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add \(selectedFileIDs.count) song(s) to another playlist or album")
        }
        .alert("Delete Selected Files", isPresented: $showingBatchDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                for file in selectedSongsInAlbumOrder {
                    audioManager.deleteAudioFile(file)
                }
                selectedFileIDs.removeAll()
                isMultiSelectMode = false
            }
        } message: {
            Text("Are you sure you want to permanently delete \(selectedFileIDs.count) file(s)? This action cannot be undone.")
        }
        .alert("Remove from Album", isPresented: $showingBatchRemoveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let album {
                    audioManager.removeAudioFiles(selectedSongsInAlbumOrder, from: album)
                }
                selectedFileIDs.removeAll()
                isMultiSelectMode = false
            }
        } message: {
            if let album {
                Text("Remove \(selectedFileIDs.count) song(s) from '\(album.name)'?")
            }
        }
    }

    // MARK: - Header

    private func albumHeader(_ album: Playlist, songs: [AudioFile], cover: UIImage?) -> some View {
        let totalDuration = songs.reduce(0) { $0 + Double($1.audioDuration) }

        return VStack(spacing: 10) {
            Button {
                artworkTarget = .playlist(album)
            } label: {
                AlbumCoverThumbnail(cover: cover, cornerRadius: 14)
                    .frame(maxWidth: 240)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
            .buttonStyle(.plain)

            Button {
                renamingAlbumName = album.name
                showingRenameAlbumAlert = true
            } label: {
                Text(album.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(theme.textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            .buttonStyle(.plain)

            Button {
                artistName = album.artist ?? ""
                showingArtistAlert = true
            } label: {
                Text(album.artist ?? "Add Artist")
                    .font(.subheadline)
                    .foregroundStyle(album.artist == nil ? theme.secondaryTextColor : theme.accentColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Text("\(songs.count) songs · \(formatDuration(totalDuration))")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Playlists and albums, minus the one these songs are already in.
    private func transferTargets(excluding album: Playlist) -> [Playlist] {
        audioManager.sortedPlaylists.filter { $0.id != album.id }
            + audioManager.sortedAlbums.filter { $0.id != album.id }
    }

    /// The selection in album order. `selectedFileIDs` is a `Set`, so iterating
    /// it directly would add songs in an arbitrary order.
    private var selectedSongsInAlbumOrder: [AudioFile] {
        albumSongs.filter { selectedFileIDs.contains($0.id) }
    }

    private func formatDuration(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Add Songs

struct AddSongsToAlbumSheet: View {
    let album: Playlist
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    private var albumSongIDs: Set<UUID> {
        Set(album.audioFileIDs)
    }

    /// Only songs not already in the album; removal is handled by the swipe
    /// action and the multi-select menu.
    private var candidates: [AudioFile] {
        audioManager.displayedSongs.filter { !albumSongIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        !candidates.isEmpty && candidates.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(theme.accentColor.opacity(0.8))
                        Text("Every song is already in this album")
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(candidates) { audioFile in
                            Button {
                                if selectedIDs.contains(audioFile.id) {
                                    selectedIDs.remove(audioFile.id)
                                } else {
                                    selectedIDs.insert(audioFile.id)
                                }
                            } label: {
                                AudioFileRow(
                                    audioFile: audioFile,
                                    isCurrentlyPlaying: false,
                                    audioManager: audioManager,
                                    isMultiSelectMode: true,
                                    isSelected: selectedIDs.contains(audioFile.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.clear)
            .navigationTitle("Add to \(album.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("All") {
                        if allSelected {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(candidates.map { $0.id })
                        }
                    }
                    .tint(theme.accentColor)
                    .disabled(candidates.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add \(selectedIDs.count)") {
                        // In `candidates` order, not `selectedIDs` order: the
                        // latter is a `Set`, so iterating it would add the songs
                        // in an arbitrary order.
                        audioManager.addAudioFiles(
                            candidates.filter { selectedIDs.contains($0.id) },
                            to: album
                        )
                        dismiss()
                    }
                    .tint(theme.accentColor)
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }
}

// MARK: - Empty State

struct EmptyAlbumView: View {
    @EnvironmentObject var theme: ThemeManager
    @Binding var showingCreateAlbumAlert: Bool
    @Binding var newAlbumName: String
    @Binding var newAlbumArtist: String

    var body: some View {
        VStack(spacing: 0) {
            AddActionButton(title: "Create Album") {
                newAlbumName = ""
                newAlbumArtist = ""
                showingCreateAlbumAlert = true
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .padding(.leading, 5)

            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(theme.accentColor.opacity(0.8))
                Text("No albums   (ᐢ.  ̫.ᐢ)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accentColor.opacity(0.8))
            }

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}
