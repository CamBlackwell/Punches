import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @State private var showingFilePicker = false
    @State private var navigateToPlayer = false
    @State private var selectedAudioFile: AudioFile?
    @State private var libraryFilter: LibraryFilter = .songs
    @State private var showingCreatePlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showingRenameAlert = false
    @State private var renamingAudioFile: AudioFile?
    @State private var newFileName = ""
    @State private var showingRenamePlaylistAlert = false
    @State private var renamingPlaylist: Playlist?
    @State private var newPlaylistNameRename = ""
    @State private var isReorderMode = false
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var artworkTarget: ArtworkTarget?
    @State private var isMultiSelectMode = false
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var showingBatchPlaylistMenu = false
    @State private var showingBatchDeleteAlert = false
    @State private var showingSettings = false

    
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                theme.backgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    TabView(selection: $libraryFilter) {
                        playlistsPage
                            .tag(LibraryFilter.playlists)

                        songsPage
                            .tag(LibraryFilter.songs)

                        playerPage
                            .tag(LibraryFilter.player)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if audioManager.currentlyPlayingID != nil
                        && !isMultiSelectMode
                        && libraryFilter != .player {
                        Divider()
                        MiniPlayerBar(
                            audioManager: audioManager,
                            navigateToPlayer: $navigateToPlayer,
                            selectedAudioFile: $selectedAudioFile
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if libraryFilter != .player {
                        bottomTabBar
                    }
                }
            }
            .toolbar { toolbarContent }
            .navigationDestination(isPresented: $showingSettings) {
                SettingsView()
            }
            .applySheets(
                showingFilePicker: $showingFilePicker,
                showingSettings: $showingSettings,
                showingShareSheet: $showingShareSheet,
                shareURL: $shareURL,
                artworkTarget: $artworkTarget,
                audioManager: audioManager
            )
            .applyAlerts(
                showingBatchPlaylistMenu: $showingBatchPlaylistMenu,
                showingBatchDeleteAlert: $showingBatchDeleteAlert,
                showingCreatePlaylistAlert: $showingCreatePlaylistAlert,
                showingRenameAlert: $showingRenameAlert,
                showingRenamePlaylistAlert: $showingRenamePlaylistAlert,
                newPlaylistName: $newPlaylistName,
                newFileName: $newFileName,
                newPlaylistNameRename: $newPlaylistNameRename,
                renamingAudioFile: $renamingAudioFile,
                renamingPlaylist: $renamingPlaylist,
                selectedFileIDs: $selectedFileIDs,
                isMultiSelectMode: $isMultiSelectMode,
                audioManager: audioManager
            )
            .onChange(of: navigateToPlayer) { _, newValue in
                if newValue {
                    libraryFilter = .player
                    navigateToPlayer = false
                }
            }
        }
        .tint(theme.tint)
    }

    private var playlistsPage: some View {
        ZStack {
            if audioManager.playlists.count == 1 {
                EmptyPlaylistView(
                    showingCreatePlaylistAlert: $showingCreatePlaylistAlert,
                    newPlaylistName: $newPlaylistName
                )
            } else {
                PlaylistsListView(
                    audioManager: audioManager,
                    navigateToPlayer: $navigateToPlayer,
                    selectedAudioFile: $selectedAudioFile,
                    showingRenameAlert: $showingRenameAlert,
                    renamingAudioFile: $renamingAudioFile,
                    newFileName: $newFileName,
                    showingRenamePlaylistAlert: $showingRenamePlaylistAlert,
                    renamingPlaylist: $renamingPlaylist,
                    newPlaylistNameRename: $newPlaylistNameRename,
                    artworkTarget: $artworkTarget,
                    showingCreatePlaylistAlert: $showingCreatePlaylistAlert,
                    newPlaylistName: $newPlaylistName
                )
            }
        }
    }

    private var songsPage: some View {
        ZStack {
            if audioManager.audioFiles.isEmpty {
                EmptySongStateView(showingFilePicker: $showingFilePicker)
            } else {
                SongsListView(
                    audioManager: audioManager,
                    navigateToPlayer: $navigateToPlayer,
                    selectedAudioFile: $selectedAudioFile,
                    showingRenameAlert: $showingRenameAlert,
                    renamingAudioFile: $renamingAudioFile,
                    newFileName: $newFileName,
                    isReorderMode: $isReorderMode,
                    artworkTarget: $artworkTarget,
                    isMultiSelectMode: $isMultiSelectMode,
                    selectedFileIDs: $selectedFileIDs,
                    showingFilePicker: $showingFilePicker
                )
            }
        }
    }

    private var playerPage: some View {
        ZStack {
            if let file = selectedAudioFile ?? audioManager.audioFiles.first {
                AudioPlayerView(
                    audioFile: file,
                    audioManager: audioManager
                )
            } else {
                Color.clear
            }
        }
    }

    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            leadingToolbarButton
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            trailingToolbarButton
        }
    }
    
    private var leadingToolbarButton: some View {
        Group {
            if libraryFilter == .player {
                Button {
                    withAnimation {
                        libraryFilter = .songs
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title2)
                }
                .tint(theme.accentColor)
            } else {
                if !isReorderMode && !isMultiSelectMode {
                    Button {
                        isMultiSelectMode = true
                        selectedFileIDs.removeAll()
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                    }
                    .tint(theme.accentColor)
                } else if isMultiSelectMode {
                    Button {
                        if selectedFileIDs.count == audioManager.displayedSongs.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(audioManager.displayedSongs.map { $0.id })
                        }
                    } label: {
                        Text("Select All")
                    }
                    .tint(theme.accentColor)
                }
            }
        }
    }

    
    private var trailingToolbarButton: some View {
        Group {
            if libraryFilter == .player {

            } else if isReorderMode {
                Button {
                    isReorderMode = false
                } label: {
                    Text("Done")
                }
                .tint(theme.accentColor)

            } else if isMultiSelectMode {
                Button {
                    isMultiSelectMode = false
                    selectedFileIDs.removeAll()
                } label: {
                    Text("Done")
                }
                .tint(theme.accentColor)

            } else {
                Menu {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Add Songs", systemImage: "music.note")
                    }
                    Button {
                        showingCreatePlaylistAlert = true
                    } label: {
                        Label("Add playlist", systemImage: "music.note.list")
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                }
                .tint(theme.accentColor)
            }
        }
    }



    private var bottomTabBar: some View {
        HStack(spacing: 0) {
            BottomTabButton(
                icon: "music.note.list",
                title: "Playlists",
                isSelected: libraryFilter == .playlists,
                action: { libraryFilter = .playlists }
            )

            BottomTabButton(
                icon: "music.note",
                title: "Songs",
                isSelected: libraryFilter == .songs,
                action: { libraryFilter = .songs }
            )

            BottomTabButton(
                icon: "play.circle.fill",
                title: "Player",
                isSelected: libraryFilter == .player,
                isDisabled: audioManager.audioFiles.isEmpty,
                action: {
                    if let currentFile = audioManager.audioFiles.first(where: {
                        $0.id == audioManager.currentlyPlayingID
                    }) {
                        selectedAudioFile = currentFile
                    } else if let firstFile = audioManager.audioFiles.first {
                        selectedAudioFile = firstFile
                    }
                    libraryFilter = .player
                }
            )
        }
        .frame(height: 45)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(edges: .bottom)
    }
}



struct BottomTabButton: View {
    @EnvironmentObject var theme: ThemeManager
    let icon: String
    let title: String
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(
                isSelected ? theme.accentColor : theme.secondaryTextColor
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 0)
        }
        .disabled(isDisabled)
    }
}

extension View {
    func applySheets(
        showingFilePicker: Binding<Bool>,
        showingSettings: Binding<Bool>,
        showingShareSheet: Binding<Bool>,
        shareURL: Binding<URL?>,
        artworkTarget: Binding<ArtworkTarget?>,
        audioManager: AudioManager
    ) -> some View {
        self
            .sheet(isPresented: showingFilePicker) {
                DocumentPicker(audioManager: audioManager)
            }
            .sheet(isPresented: showingShareSheet) {
                if let url = shareURL.wrappedValue {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(item: artworkTarget) { target in
                PhotoPicker { image in
                    switch target {
                    case .audioFile(let file):
                        audioManager.setArtwork(image, for: file)
                    case .playlist(let playlist):
                        audioManager.setArtwork(image, for: playlist)
                    case .multipleFiles(let fileIDs):
                        for fileID in fileIDs {
                            if let file = audioManager.audioFiles.first(where: {
                                $0.id == fileID
                            }) {
                                audioManager.setArtwork(image, for: file)
                            }
                        }
                    }
                }
            }
    }

    func applyAlerts(
        showingBatchPlaylistMenu: Binding<Bool>,
        showingBatchDeleteAlert: Binding<Bool>,
        showingCreatePlaylistAlert: Binding<Bool>,
        showingRenameAlert: Binding<Bool>,
        showingRenamePlaylistAlert: Binding<Bool>,
        newPlaylistName: Binding<String>,
        newFileName: Binding<String>,
        newPlaylistNameRename: Binding<String>,
        renamingAudioFile: Binding<AudioFile?>,
        renamingPlaylist: Binding<Playlist?>,
        selectedFileIDs: Binding<Set<UUID>>,
        isMultiSelectMode: Binding<Bool>,
        audioManager: AudioManager
    ) -> some View {
        self
            .confirmationDialog(
                "Add to Playlist",
                isPresented: showingBatchPlaylistMenu
            ) {
                let playlists = audioManager.sortedPlaylists
                ForEach(playlists) { playlist in
                    Button(playlist.name) {
                        for fileID in selectedFileIDs.wrappedValue {
                            if let file = audioManager.audioFiles.first(where: {
                                $0.id == fileID
                            }) {
                                audioManager.addAudioFile(file, to: playlist)
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Delete Selected Files",
                isPresented: showingBatchDeleteAlert
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    for fileID in selectedFileIDs.wrappedValue {
                        if let file = audioManager.audioFiles.first(where: {
                            $0.id == fileID
                        }) {
                            audioManager.deleteAudioFile(file)
                        }
                    }
                    selectedFileIDs.wrappedValue.removeAll()
                    isMultiSelectMode.wrappedValue = false
                }
            } message: {
                Text(
                    "Are you sure you want to delete \(selectedFileIDs.wrappedValue.count) file(s)? This action cannot be undone."
                )
            }
            .alert("New Playlist", isPresented: showingCreatePlaylistAlert) {
                TextField("Playlist Name", text: newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    if !newPlaylistName.wrappedValue.isEmpty {
                        audioManager.createPlaylist(
                            name: newPlaylistName.wrappedValue
                        )
                    }
                }
            }
            .alert("Rename File", isPresented: showingRenameAlert) {
                TextField("New Name", text: newFileName)
                Button("Cancel", role: .cancel) {
                    renamingAudioFile.wrappedValue = nil
                    newFileName.wrappedValue = ""
                }
                Button("Rename") {
                    if let audioFile = renamingAudioFile.wrappedValue,
                        !newFileName.wrappedValue.isEmpty
                    {
                        audioManager.renameAudioFile(
                            audioFile,
                            to: newFileName.wrappedValue
                        )
                    }
                    renamingAudioFile.wrappedValue = nil
                    newFileName.wrappedValue = ""
                }
            } message: {
                if let audioFile = renamingAudioFile.wrappedValue {
                    Text("Enter a new name for '\(audioFile.title)'")
                }
            }
            .alert("Rename Playlist", isPresented: showingRenamePlaylistAlert) {
                TextField("New Name", text: newPlaylistNameRename)
                Button("Cancel", role: .cancel) {
                    renamingPlaylist.wrappedValue = nil
                    newPlaylistNameRename.wrappedValue = ""
                }
                Button("Rename") {
                    if let playlist = renamingPlaylist.wrappedValue,
                        !newPlaylistNameRename.wrappedValue.isEmpty
                    {
                        audioManager.renamePlaylist(
                            playlist,
                            to: newPlaylistNameRename.wrappedValue
                        )
                    }
                    renamingPlaylist.wrappedValue = nil
                    newPlaylistNameRename.wrappedValue = ""
                }
            } message: {
                if let playlist = renamingPlaylist.wrappedValue {
                    Text("Enter a new name for '\(playlist.name)'")
                }
            }
    }
}

struct LibraryListView: View {
    @ObservedObject var audioManager: AudioManager
    let filter: LibraryFilter
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var showingRenamePlaylistAlert: Bool
    @Binding var renamingPlaylist: Playlist?
    @Binding var newPlaylistNameRename: String
    @Binding var isReorderMode: Bool
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var isMultiSelectMode: Bool
    @Binding var selectedFileIDs: Set<UUID>
    @Binding var showingFilePicker: Bool
    @Binding var showingCreatePlaylistAlert: Bool
    @Binding var newPlaylistName: String

    var body: some View {
        switch filter {
        case .songs:
            SongsListView(
                audioManager: audioManager,
                navigateToPlayer: $navigateToPlayer,
                selectedAudioFile: $selectedAudioFile,
                showingRenameAlert: $showingRenameAlert,
                renamingAudioFile: $renamingAudioFile,
                newFileName: $newFileName,
                isReorderMode: $isReorderMode,
                artworkTarget: $artworkTarget,
                isMultiSelectMode: $isMultiSelectMode,
                selectedFileIDs: $selectedFileIDs,
                showingFilePicker: $showingFilePicker
            )
        case .playlists:
            PlaylistsListView(
                audioManager: audioManager,
                navigateToPlayer: $navigateToPlayer,
                selectedAudioFile: $selectedAudioFile,
                showingRenameAlert: $showingRenameAlert,
                renamingAudioFile: $renamingAudioFile,
                newFileName: $newFileName,
                showingRenamePlaylistAlert: $showingRenamePlaylistAlert,
                renamingPlaylist: $renamingPlaylist,
                newPlaylistNameRename: $newPlaylistNameRename,
                artworkTarget: $artworkTarget,
                showingCreatePlaylistAlert: $showingCreatePlaylistAlert,
                newPlaylistName: $newPlaylistName
            )
        case .player:
            if let audioFile = selectedAudioFile {
                AudioPlayerView(
                    audioFile: audioFile,
                    audioManager: audioManager
                )
            }
        }
    }
}

struct SongsListView: View {
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var isReorderMode: Bool
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var isMultiSelectMode: Bool
    @Binding var selectedFileIDs: Set<UUID>
    @Binding var showingFilePicker: Bool
    @Environment(\.editMode) private var editMode
    @State private var showingShareSheet = false
    @State private var shareURLs: [URL] = []
    @State private var showingBatchPlaylistMenu = false
    @State private var showingBatchDeleteAlert = false

    var sortedSongs: [AudioFile] { audioManager.displayedSongs }

    var body: some View {
        List {
            AddActionButton(title: "Add Songs") {
                showingFilePicker = true
            }
            .listRowBackground(theme.backgroundColor)
            .listRowSeparator(.hidden)
            .padding(.bottom, 0)
            
            

            ForEach(sortedSongs, id: \.id) { audioFile in
                AudioFileButton(
                    audioFile: audioFile,
                    audioManager: audioManager,
                    navigateToPlayer: $navigateToPlayer,
                    selectedAudioFile: $selectedAudioFile,
                    showingRenameAlert: $showingRenameAlert,
                    renamingAudioFile: $renamingAudioFile,
                    newFileName: $newFileName,
                    context: sortedSongs,
                    isFromSongsTab: true,
                    isReorderMode: isReorderMode,
                    showingShareSheet: $showingShareSheet,
                    shareURLs: $shareURLs,
                    artworkTarget: $artworkTarget,
                    isMultiSelectMode: isMultiSelectMode,
                    selectedFileIDs: $selectedFileIDs,
                    showingBatchPlaylistMenu: $showingBatchPlaylistMenu,
                    showingBatchDeleteAlert: $showingBatchDeleteAlert
                )
                .listRowBackground(theme.backgroundColor)
                .listRowSeparator(.hidden)

            }
            .onMove { source, destination in
                if isMultiSelectMode && !selectedFileIDs.isEmpty {
                    let selectedIndices = sortedSongs.enumerated()
                        .filter { selectedFileIDs.contains($0.element.id) }
                        .map { $0.offset }

                    if source.allSatisfy({ selectedIndices.contains($0) }) {
                        audioManager.reorderSelectedSongs(
                            selectedIDs: Array(selectedFileIDs),
                            to: destination,
                            in: sortedSongs
                        )
                    }
                } else {
                    audioManager.reorderSongs(from: source, to: destination)
                }
            }

            //Color.clear.frame(height: 35).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
        .environment(
            \.editMode,
            (isReorderMode || isMultiSelectMode)
                ? .constant(.active) : .constant(.inactive)
        )
        .sheet(
            isPresented: $showingShareSheet,
            onDismiss: {
                for url in self.shareURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                self.shareURLs.removeAll()
            } as (() -> Void)
        ) {
            ShareSheet(activityItems: shareURLs)
        }
        .confirmationDialog(
            "Add to Playlist",
            isPresented: $showingBatchPlaylistMenu
        ) {
            let playlists = audioManager.sortedPlaylists
            ForEach(playlists) { playlist in
                Button(playlist.name) {
                    for fileID in selectedFileIDs {
                        if let file = audioManager.audioFiles.first(where: {
                            $0.id == fileID
                        }) {
                            audioManager.addAudioFile(file, to: playlist)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add \(selectedFileIDs.count) song(s) to playlist")
        }
        .alert("Delete Selected Files", isPresented: $showingBatchDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                for fileID in selectedFileIDs {
                    if let file = audioManager.audioFiles.first(where: {
                        $0.id == fileID
                    }) {
                        audioManager.deleteAudioFile(file)
                    }
                }
                selectedFileIDs.removeAll()
                isMultiSelectMode = false
            }
        } message: {
            Text(
                "Are you sure you want to delete \(selectedFileIDs.count) file(s)? This action cannot be undone."
            )
        }
    }
}

struct PlaylistsListView: View {
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var showingRenamePlaylistAlert: Bool
    @Binding var renamingPlaylist: Playlist?
    @Binding var newPlaylistNameRename: String
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var showingCreatePlaylistAlert: Bool
    @Binding var newPlaylistName: String

    var body: some View {
        List {
            AddActionButton(title: "Create Playlist") {
                newPlaylistName = ""
                showingCreatePlaylistAlert = true
            }
            .listRowBackground(theme.backgroundColor)
            .listRowSeparator(.hidden)
            .padding(.bottom, 0)

            ForEach(audioManager.sortedPlaylists) { playlist in
                NavigationLink(
                    destination: PlaylistDetailView(
                        playlist: playlist,
                        audioManager: audioManager,
                        navigateToPlayer: $navigateToPlayer,
                        selectedAudioFile: $selectedAudioFile,
                        showingRenameAlert: $showingRenameAlert,
                        renamingAudioFile: $renamingAudioFile,
                        newFileName: $newFileName,
                        artworkTarget: $artworkTarget
                    )
                ) {
                    PlaylistRowView(
                        playlist: playlist,
                        audioManager: audioManager
                    )
                }
                .listRowBackground(theme.backgroundColor)
                .listRowSeparator(.hidden)
                .contextMenu {
                    Button(
                        playlist.artworkImageName == nil
                            ? "Set Artwork" : "Change Artwork",
                        systemImage: "photo"
                    ) {
                        artworkTarget = .playlist(playlist)
                    }
                    if playlist.artworkImageName != nil {
                        Button(
                            "Remove Artwork",
                            systemImage: "photo.badge.minus",
                            role: .destructive
                        ) {
                            audioManager.removeArtwork(from: playlist)
                        }
                    }
                    Button("rename", systemImage: "pencil.and.outline") {
                        renamingPlaylist = playlist
                        newPlaylistNameRename = playlist.name
                        showingRenamePlaylistAlert = true
                    }
                    Button(role: .destructive) {
                        audioManager.deletePlaylist(playlist)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            //Color.clear.frame(height: 35).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
    }
}

struct MiniPlayerBar: View {
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?

    var currentAudioFile: AudioFile? {
        audioManager.audioFiles.first {
            $0.id == audioManager.currentlyPlayingID
        }
    }

    var body: some View {
        if let audioFile = currentAudioFile {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        selectedAudioFile = audioFile
                        navigateToPlayer = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(audioFile.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .foregroundStyle(theme.textColor)

                            HStack {
                                Text(
                                    formatTime(Float(audioManager.currentTime))
                                )
                                .font(.caption)
                                .foregroundStyle(theme.secondaryTextColor)
                                Spacer()
                                Text(formatTime(audioFile.audioDuration))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryTextColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    HStack(spacing: 20) {
                        Button(action: { audioManager.skipPreviousSong() }) {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                        .buttonStyle(.plain)

                        Button {
                            audioManager.togglePlayPause()
                        } label: {
                            Image(
                                systemName: audioManager.isPlaying
                                    ? "pause.fill" : "play.fill"
                            )
                            .font(.title2)
                            .foregroundStyle(theme.accentColor)
                        }
                        .buttonStyle(.plain)

                        Button(action: { audioManager.skipNextSong() }) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(theme.backgroundColor.opacity(0.3))
                            .frame(height: 3)

                        Rectangle()
                            .fill(theme.accentColor)
                            .frame(
                                width: geometry.size.width * progressPercentage,
                                height: 3
                            )
                    }
                }
                .frame(height: 3)
            }
            .background(.ultraThinMaterial)
        }
    }

    private var progressPercentage: CGFloat {
        guard audioManager.duration > 0 else { return 0 }
        return CGFloat(audioManager.currentTime / audioManager.duration)
    }

    private func formatTime(_ time: Float) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct PlaylistRowView: View {
    let playlist: Playlist
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager

    var artworkImage: UIImage? {
        guard
            let currentPlaylist = audioManager.playlists.first(where: {
                $0.id == playlist.id
            }),
            let artworkName = currentPlaylist.artworkImageName
        else {
            return nil
        }

        return audioManager.artworkService.loadArtworkImage(artworkName)
    }

    var playlistSongs: [AudioFile] {
        audioManager.getAudioFiles(for: playlist)
    }

    var body: some View {
        HStack {
            if let image = artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 35, height: 35)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 30)
            }

            VStack(alignment: .leading) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(theme.textColor)

                Text("\(playlistSongs.count) songs")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }

            Spacer()
        }
    }
}

struct EmptySongStateView: View {
    @EnvironmentObject var theme: ThemeManager
    @Binding var showingFilePicker: Bool

    var body: some View {
        VStack(spacing: 0) {
            AddActionButton(title: "Add Songs") {
                showingFilePicker = true
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .padding(.leading, 5)
            .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(theme.accentColor.opacity(0.8))
                Text("No audio Files .·°ღ(¯`□´¯)ღ°·.")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accentColor.opacity(0.8))
            }

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

struct EmptyPlaylistView: View {
    @EnvironmentObject var theme: ThemeManager
    @Binding var showingCreatePlaylistAlert: Bool
    @Binding var newPlaylistName: String

    var body: some View {
        VStack(spacing: 0) {
            AddActionButton(title: "Create Playlist") {
                newPlaylistName = ""
                showingCreatePlaylistAlert = true
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .padding(.leading, 5)

            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(theme.accentColor.opacity(0.8))
                Text("No playlists   ༼ ༎ຶ ෴ ༎ຶ༽")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accentColor.opacity(0.8))
            }

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

struct AudioFileButton: View {
    let audioFile: AudioFile
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    var context: [AudioFile]? = nil
    var isFromSongsTab: Bool = false
    var isReorderMode: Bool = false
    @Binding var showingShareSheet: Bool
    @Binding var shareURLs: [URL]
    @Binding var artworkTarget: ArtworkTarget?
    var isMultiSelectMode: Bool = false
    @Binding var selectedFileIDs: Set<UUID>
    @Binding var showingBatchPlaylistMenu: Bool
    @Binding var showingBatchDeleteAlert: Bool

    var body: some View {
        Button {
            if isMultiSelectMode {
                if selectedFileIDs.contains(audioFile.id) {
                    selectedFileIDs.remove(audioFile.id)
                } else {
                    selectedFileIDs.insert(audioFile.id)
                }
            } else if !isReorderMode {
                let isSameSong = audioManager.currentlyPlayingID == audioFile.id
                let isSameContext =
                    audioManager.playingFromSongsTab == isFromSongsTab
                if isSameSong && isSameContext {
                    selectedAudioFile = audioFile
                    navigateToPlayer = true
                } else {
                    audioManager.play(
                        audioFile: audioFile,
                        context: context,
                        fromSongsTab: isFromSongsTab
                    )
                }
            }
        } label: {
            AudioFileRow(
                audioFile: audioFile,
                isCurrentlyPlaying: audioManager.currentlyPlayingID
                    == audioFile.id
                    && audioManager.playingFromSongsTab == isFromSongsTab,
                audioManager: audioManager,
                isMultiSelectMode: isMultiSelectMode,
                isSelected: selectedFileIDs.contains(audioFile.id)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .background(theme.backgroundColor)
        .contextMenu {
            if !isReorderMode {
                if isMultiSelectMode && selectedFileIDs.contains(audioFile.id) {
                    MultiSelectContextMenu(
                        audioManager: audioManager,
                        selectedFileIDs: selectedFileIDs,
                        showingShareSheet: $showingShareSheet,
                        shareURLs: $shareURLs,
                        artworkTarget: $artworkTarget,
                        showingBatchPlaylistMenu: $showingBatchPlaylistMenu,
                        showingBatchDeleteAlert: $showingBatchDeleteAlert
                    )
                } else {
                    AudioFileContextMenu(
                        audioFile: audioFile,
                        audioManager: audioManager,
                        showingRenameAlert: $showingRenameAlert,
                        renamingAudioFile: $renamingAudioFile,
                        newFileName: $newFileName,
                        showingShareSheet: $showingShareSheet,
                        shareURLs: $shareURLs,
                        artworkTarget: $artworkTarget
                    )
                }
            }
        }
    }
}

struct MultiSelectContextMenu: View {
    @ObservedObject var audioManager: AudioManager
    let selectedFileIDs: Set<UUID>
    @Binding var showingShareSheet: Bool
    @Binding var shareURLs: [URL]
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var showingBatchPlaylistMenu: Bool
    @Binding var showingBatchDeleteAlert: Bool

    var body: some View {
        Button(
            "Share \(selectedFileIDs.count) Files",
            systemImage: "square.and.arrow.up"
        ) {
            shareURLs = prepareFilesForSharing()
            showingShareSheet = true
        }

        Button(
            "Set Artwork for \(selectedFileIDs.count) Files",
            systemImage: "photo"
        ) {
            artworkTarget = .multipleFiles(selectedFileIDs)
        }

        Button(
            "Add \(selectedFileIDs.count) to Playlist",
            systemImage: "text.badge.plus"
        ) {
            showingBatchPlaylistMenu = true
        }

        Button(
            "Delete \(selectedFileIDs.count) Files",
            systemImage: "trash",
            role: .destructive
        ) {
            showingBatchDeleteAlert = true
        }
    }

    private func prepareFilesForSharing() -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        var tempURLs: [URL] = []

        for fileID in selectedFileIDs {
            guard let file = audioManager.audioFiles.first(where: { $0.id == fileID }) else { continue }

            let fileURL = file.fileURL
            let tempURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
            
            do {
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                tempURLs.append(tempURL)
            } catch {
                print("Error copying file for sharing: \(error)")
            }
        }

        return tempURLs
    }
}

struct AddActionButton: View {
    @EnvironmentObject var theme: ThemeManager
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center) {
                /*Image(systemName: "plus.square.fill")
                    .font(.title2)
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 35, height: 35)
                    .padding(.leading, 8)
                 */
                Spacer()
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.accentColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                
                Spacer()
            }
        }
    }
}

struct AudioFileRow: View {
    let audioFile: AudioFile
    let isCurrentlyPlaying: Bool
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    var isMultiSelectMode: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack {
            if isMultiSelectMode {
                Image(
                    systemName: isSelected ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(
                    isSelected ? theme.accentColor : theme.secondaryTextColor
                )
                .font(.title2)
            }

            if let artworkName = audioFile.artworkImageName,
               let image = audioManager.artworkService.loadArtworkImage(artworkName)
            {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 35, height: 35)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isCurrentlyPlaying ? theme.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    )
            } else {
                Image(
                    systemName: isCurrentlyPlaying
                        ? "face.smiling.fill" : "face.smiling"
                ).foregroundStyle(
                    isCurrentlyPlaying
                        ? theme.accentColor : theme.secondaryTextColor
                )
                .font(.title2)
                .frame(width: 35, height: 35)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(audioFile.title)
                    .font(.headline)
                    .foregroundStyle(
                        isCurrentlyPlaying ? theme.accentColor : theme.textColor
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                HStack {
                    Text(audioFile.dateAdded, style: .date)
                    Text(formatTime(audioFile.audioDuration))
                }
                .font(.caption).foregroundStyle(theme.secondaryTextColor)
                .lineLimit(1)
            }
            Spacer()
            if isCurrentlyPlaying && !isMultiSelectMode {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(
                    theme.accentColor
                ).font(.caption)
            }
        }
        //.padding(.vertical, 4)
    }
    private func formatTime(_ time: Float) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }
    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}

struct AudioFileContextMenu: View {
    let audioFile: AudioFile
    @ObservedObject var audioManager: AudioManager
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var showingShareSheet: Bool
    @Binding var shareURLs: [URL]
    @Binding var artworkTarget: ArtworkTarget?
    var body: some View {
        Button("share this file", systemImage: "square.and.arrow.up") {
            if let url = audioManager.urlForSharing(audioFile) {
                shareURLs = [url]
                showingShareSheet = true
            }
        }
        Button(
            audioFile.artworkImageName == nil
                ? "Set Artwork" : "Change Artwork",
            systemImage: "photo"
        ) {
            artworkTarget = .audioFile(audioFile)
        }
        if audioFile.artworkImageName != nil {
            Button(
                "Remove Artwork",
                systemImage: "photo.badge.minus",
                role: .destructive
            ) { audioManager.removeArtwork(from: audioFile) }
        }
        Button("rename", systemImage: "pencil.and.outline") {
            renamingAudioFile = audioFile
            newFileName = audioFile.title
            showingRenameAlert = true
        }
        Menu {
            ForEach(audioManager.sortedPlaylists) { playlist in
                Button(playlist.name) {
                    audioManager.addAudioFile(audioFile, to: playlist)
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "plus")
        }
        Button(role: .destructive) {
            audioManager.deleteAudioFile(audioFile)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let audioManager: AudioManager
    @Environment(\.dismiss) var dismiss
    func makeUIViewController(context: Context)
        -> UIDocumentPickerViewController
    {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .audio
        ])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(
        _ ui: UIDocumentPickerViewController,
        context: Context
    ) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }
        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            for url in urls { parent.audioManager.importAudioFile(from: url) }
            parent.dismiss()
        }
        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) { parent.dismiss() }
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: PHPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            parent.dismiss()

            guard let result = results.first else { return }

            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }

                DispatchQueue.main.async {
                    self.parent.onImagePicked(image)
                }
            }
        }
    }
}
