import SwiftUI
import PhotosUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var audioManager: AudioManager
    @EnvironmentObject var theme: ThemeManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    @Binding var artworkTarget: ArtworkTarget?
    @State private var isReorderMode = false
    @State private var showingShareSheet = false
    @State private var shareURLs: [URL] = []
    @State private var isMultiSelectMode = false
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var showingBatchDeleteAlert = false
    @State private var showingBatchRemoveAlert = false
    @State private var showingBatchPlaylistMenu = false
    
    var playlistSongs: [AudioFile] {
        audioManager.getAudioFiles(for: playlist)
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(theme.backgroundColor)
                .ignoresSafeArea()
            
            VStack {
                if playlistSongs.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .foregroundStyle(theme.accentColor.opacity(0.8))
                        Text("This playlist is empty")
                            .foregroundStyle(theme.secondaryTextColor)
                        Text("Go to Songs view and use the context menu to add songs here")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryTextColor)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(playlistSongs) { audioFile in
                            PlaylistAudioFileButton(
                                audioFile: audioFile,
                                playlist: playlist,
                                audioManager: audioManager,
                                navigateToPlayer: $navigateToPlayer,
                                selectedAudioFile: $selectedAudioFile,
                                showingRenameAlert: $showingRenameAlert,
                                renamingAudioFile: $renamingAudioFile,
                                newFileName: $newFileName,
                                context: playlistSongs,
                                isReorderMode: isReorderMode,
                                showingShareSheet: $showingShareSheet,
                                shareURLs: $shareURLs,
                                artworkTarget: $artworkTarget,
                                isMultiSelectMode: isMultiSelectMode,
                                selectedFileIDs: $selectedFileIDs,
                                showingBatchPlaylistMenu: $showingBatchPlaylistMenu,
                                showingBatchDeleteAlert: $showingBatchDeleteAlert,
                                showingBatchRemoveAlert: $showingBatchRemoveAlert
                            )
                            .swipeActions {
                                if !isReorderMode && !isMultiSelectMode {
                                    Button(role: .destructive) {
                                        audioManager.removeAudioFile(audioFile, from: playlist)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .onMove { source, destination in
                            audioManager.reorderPlaylistSongs(in: playlist, from: source, to: destination)
                        }
                        .listRowBackground(Color(theme.backgroundColor))
                        .listRowSeparator(.hidden)
                        Color.clear.frame(height: 35).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    .listStyle(PlainListStyle())
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, isReorderMode ? .constant(.active) : .constant(.inactive))
                }
            }
            
            if audioManager.currentlyPlayingID != nil && !isMultiSelectMode {
                MiniPlayerBar(
                    audioManager: audioManager,
                    navigateToPlayer: $navigateToPlayer,
                    selectedAudioFile: $selectedAudioFile
                )
            }
        }
        .background(Color(theme.backgroundColor))
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    if isMultiSelectMode {
                        Button {
                            if selectedFileIDs.count == playlistSongs.count {
                                selectedFileIDs.removeAll()
                            } else {
                                selectedFileIDs = Set(playlistSongs.map { $0.id })
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
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: shareURLs)
        }
        .confirmationDialog("Add to Playlist", isPresented: $showingBatchPlaylistMenu) {
            ForEach(audioManager.playlists.filter { $0.id != playlist.id }) { otherPlaylist in
                Button(otherPlaylist.name) {
                    for fileID in selectedFileIDs {
                        if let file = audioManager.audioFiles.first(where: { $0.id == fileID }) {
                            audioManager.addAudioFile(file, to: otherPlaylist)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Add \(selectedFileIDs.count) song(s) to another playlist")
        }
        .alert("Delete Selected Files", isPresented: $showingBatchDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                for fileID in selectedFileIDs {
                    if let file = audioManager.audioFiles.first(where: { $0.id == fileID }) {
                        audioManager.deleteAudioFile(file)
                    }
                }
                selectedFileIDs.removeAll()
                isMultiSelectMode = false
            }
        } message: {
            Text("Are you sure you want to permanently delete \(selectedFileIDs.count) file(s)? This action cannot be undone.")
        }
        .alert("Remove from Playlist", isPresented: $showingBatchRemoveAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                for fileID in selectedFileIDs {
                    if let file = audioManager.audioFiles.first(where: { $0.id == fileID }) {
                        audioManager.removeAudioFile(file, from: playlist)
                    }
                }
                selectedFileIDs.removeAll()
                isMultiSelectMode = false
            }
        } message: {
            Text("Remove \(selectedFileIDs.count) song(s) from '\(playlist.name)'?")
        }
    }
}

struct PlaylistAudioFileButton: View {
    let audioFile: AudioFile
    let playlist: Playlist
    @ObservedObject var audioManager: AudioManager
    @Binding var navigateToPlayer: Bool
    @Binding var selectedAudioFile: AudioFile?
    @Binding var showingRenameAlert: Bool
    @Binding var renamingAudioFile: AudioFile?
    @Binding var newFileName: String
    var context: [AudioFile]? = nil
    var isReorderMode: Bool = false
    @Binding var showingShareSheet: Bool
    @Binding var shareURLs: [URL]
    @Binding var artworkTarget: ArtworkTarget?
    var isMultiSelectMode: Bool = false
    @Binding var selectedFileIDs: Set<UUID>
    @Binding var showingBatchPlaylistMenu: Bool
    @Binding var showingBatchDeleteAlert: Bool
    @Binding var showingBatchRemoveAlert: Bool

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
                let isSameContext = audioManager.playingFromSongsTab == false
                if isSameSong && isSameContext {
                    selectedAudioFile = audioFile
                    navigateToPlayer = true
                } else {
                    audioManager.play(audioFile: audioFile, context: context, fromSongsTab: false)
                }
            }
        } label: {
            AudioFileRow(
                audioFile: audioFile,
                isCurrentlyPlaying: audioManager.currentlyPlayingID == audioFile.id && audioManager.playingFromSongsTab == false,
                audioManager: audioManager,
                isMultiSelectMode: isMultiSelectMode,
                isSelected: selectedFileIDs.contains(audioFile.id)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            if !isReorderMode {
                if isMultiSelectMode && selectedFileIDs.contains(audioFile.id) {
                    PlaylistMultiSelectContextMenu(
                        audioManager: audioManager,
                        playlist: playlist,
                        selectedFileIDs: selectedFileIDs,
                        showingShareSheet: $showingShareSheet,
                        shareURLs: $shareURLs,
                        artworkTarget: $artworkTarget,
                        showingBatchPlaylistMenu: $showingBatchPlaylistMenu,
                        showingBatchRemoveAlert: $showingBatchRemoveAlert,
                        showingBatchDeleteAlert: $showingBatchDeleteAlert
                    )
                } else {
                    PlaylistAudioFileContextMenu(
                        audioFile: audioFile,
                        playlist: playlist,
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

struct PlaylistMultiSelectContextMenu: View {
    @ObservedObject var audioManager: AudioManager
    let playlist: Playlist
    let selectedFileIDs: Set<UUID>
    @Binding var showingShareSheet: Bool
    @Binding var shareURLs: [URL]
    @Binding var artworkTarget: ArtworkTarget?
    @Binding var showingBatchPlaylistMenu: Bool
    @Binding var showingBatchRemoveAlert: Bool
    @Binding var showingBatchDeleteAlert: Bool
    
    var body: some View {
        Button("Share \(selectedFileIDs.count) Files", systemImage: "square.and.arrow.up") {
            shareURLs = selectedFileIDs.compactMap { fileID in
                audioManager.audioFiles.first(where: { $0.id == fileID })
            }.compactMap { audioManager.urlForSharing($0) }
            showingShareSheet = true
        }
        
        Button("Set Artwork for \(selectedFileIDs.count) Files", systemImage: "photo") {
            artworkTarget = .multipleFiles(selectedFileIDs)
        }
        
        Button("Add \(selectedFileIDs.count) to Another Playlist", systemImage: "text.badge.plus") {
            showingBatchPlaylistMenu = true
        }
        
        Button("Remove \(selectedFileIDs.count) from '\(playlist.name)'", systemImage: "minus.circle") {
            showingBatchRemoveAlert = true
        }
        
        Button("Delete \(selectedFileIDs.count) Files", systemImage: "trash", role: .destructive) {
            showingBatchDeleteAlert = true
        }
    }
}

struct PlaylistAudioFileContextMenu: View {
    let audioFile: AudioFile
    let playlist: Playlist
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
        Button(audioFile.artworkImageName == nil ? "Set Artwork" : "Change Artwork", systemImage: "photo") {
            artworkTarget = .audioFile(audioFile)
        }
        if audioFile.artworkImageName != nil {
            Button("Remove Artwork", systemImage: "photo.badge.minus", role: .destructive) {
                audioManager.removeArtwork(from: audioFile)
            }
        }
        Button("rename", systemImage: "pencil.and.outline") {
            renamingAudioFile = audioFile
            newFileName = audioFile.title
            showingRenameAlert = true
        }
        Menu {
            ForEach(audioManager.playlists.filter { $0.id != playlist.id }) { otherPlaylist in
                Button(otherPlaylist.name) {
                    audioManager.addAudioFile(audioFile, to: otherPlaylist)
                }
            }
        } label: { Label("Add to Another Playlist", systemImage: "plus") }
        
        Button("Remove from '\(playlist.name)'", systemImage: "minus.circle") {
            audioManager.removeAudioFile(audioFile, from: playlist)
        }
        
        Button(role: .destructive) {
            audioManager.deleteAudioFile(audioFile)
        } label: {
            Label("Delete Permanently", systemImage: "trash")
        }
    }
}
