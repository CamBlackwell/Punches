import Foundation
import os

/// Keeps tag-derived albums in step with the library's own tags.
///
/// ## What this is for
///
/// A file library already knows which album each track belongs to. The app stored
/// that as a *column* (`AudioFile.album`) and then asked the user to make albums
/// out of it by hand, one multi-select at a time — for information the files were
/// already carrying. This builds the collections instead, and keeps them current
/// as files are added, retagged or removed.
///
/// ## Why it is a projector and not a query
///
/// An album that appears and disappears as files are imported would be alarming:
/// the Albums page is where the user looks for things they own. So a group with no
/// files leaves no album behind, and the Albums page only ever shows groups that
/// currently have songs.
///
/// ## What it must not do
///
/// The Albums page is also where hand-made albums live, so the dangerous mistake
/// here is overwriting one. Two rules prevent it, and both are load-bearing:
///
/// - **Only rows this projector created are ever touched.** A row is eligible
///   only when its `tagKey` is non-null, and `tagKey` is written only here. A
///   hand-made album has `tagKey == nil` forever, so there is no state in which
///   this can rewrite one — not even if the user gave it exactly the name of a tag
///   group.
/// - **A deletion is remembered.** Deleting a derived album is the one action a
///   user can take against it that means "I don't want this", and a projector that
///   recreated it on the next launch would make deletion feel broken. The tag is
///   recorded in `meta` and the group is left alone until the tags change enough
///   to be worth asking again. See `suppressedTags`.
///
/// A derived album is *not* locked against editing: renaming it, reordering its
/// songs or removing a song all work, and the next run preserves them. See
/// `mergedMembership`. The one thing that does not stick is adding a song, because
/// a song not in the tag group does not belong in that album, and the next run
/// would remove it again.
///
/// ## Membership order
///
/// Not rebuilt from scratch. If it were, dragging a derived album's songs into a
/// different order would be undone on the next launch — the app would appear to
/// save the change and then revert it, which is worse than not offering the
/// gesture. So the order is hybrid: songs already in the album keep their
/// positions, in the order they are in, and genuinely new songs are appended in
/// tag order. A reorder therefore survives indefinitely, and a file imported into
/// an existing group lands at the end rather than being interleaved into the
/// middle of the user's arrangement.
struct TagAlbumProjector {

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "tag-albums"
    )

    /// Where suppressed tag groups are remembered.
    ///
    /// `meta` rather than a column, because the set is small, changes only when
    /// the user deletes a derived album, and is meaningless without a projector to
    /// read it. Newline-joined rather than JSON: the values are normalised tag
    /// values, and normalisation strips whitespace including newlines, so a
    /// newline cannot occur inside one — which makes the encoding unambiguous
    /// without a decoder that can fail.
    static let suppressionKey = "tag_albums_suppressed"

    /// The tags a group can be built from, in the order they are projected.
    ///
    /// `album` is deliberately absent. A group of the album tag would be
    /// one-album-per-album, which is what the manual Albums page already does and
    /// not what a *library-wide* grouping is for. These three are the tags a
    /// listener thinks in.
    ///
    /// Declared as `GroupTag`'s own cases rather than as a list here, so adding a
    /// fourth tag cannot be forgotten in two places — `allCases` is the single
    /// source of what gets projected.
    ///
    /// `displayName` is what the album cell shows; `value(_:)` extracts and
    /// normalises the tag. `decade` reads `year` rather than a tag of its own, so
    /// it is the odd one out and gets its own case.
    enum GroupTag: String, CaseIterable, Identifiable {
        // `CaseIterable` rather than a separate list of "the tags to project", so
        // a fourth tag is projected because it exists rather than because someone
        // remembered to add it in two places.
        case genre
        case albumArtist
        case decade

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .genre: "Genre"
            case .albumArtist: "Album Artist"
            case .decade: "Decade"
            }
        }

                /// The short label shown under a derived album's name.
        ///
        /// A derived album's `artist` is left `nil` rather than being set to the
        /// group value, because `AlbumGridCell` falls back to a song count when
        /// there is no artist — and a song count is the more useful thing to see
        /// next to "Rock". So the tag that built the album is recorded on the cell
        /// itself instead, where it can be shown without lying about the album's
        /// artist field.
        static func descriptor(for key: String) -> String? {
            guard let decoded = decode(key: key) else { return nil }
            return "\(decoded.tag.displayName) · \(decoded.value)"
        }

        /// The group key for a track, or `nil` if the track does not carry it.
        ///
        /// `nil` means the track belongs to no group for this tag — no tag, an
        /// empty tag, or a tag that is only whitespace. All three mean the same
        /// thing: there is nothing to name an album after. Note `year` is only
        /// carried when a file has a `year` tag, so most files fall into no decade
        /// group at all and nothing is created for them.
        func value(for file: AudioFile) -> String? {
            switch self {
            case .genre:
                return Self.normalized(file.genre)
            case .albumArtist:
                return Self.normalized(file.albumArtist)
            case .decade:
                guard let year = file.year, year > 0 else { return nil }
                // A decade is a label, not a tag value, so it is built here and
                // normalised like any other. Years outside 1000..9999 are not
                // years; such a file is in no decade rather than in "the 0s".
                guard (1000...9999).contains(year) else { return nil }
                return "\(year / 10 * 10)s"
            }
        }

        /// The stored `tagKey` for one of this tag's group values.
        ///
        /// `tag` and a unit separator, so two tags cannot be confused for one:
        /// a genre literally called "artist: rock" must not collide with the
        /// album-artist group "rock". `U+001F` is the ASCII unit separator, which
        /// is not legal in a filesystem path or meaningful in a tag value, so it
        /// is safe as a delimiter and cannot appear in a normalised value.
        func key(for value: String) -> String {
            "\(rawValue)\u{1F}\(value)"
        }

        /// Splits a stored `tagKey` back into its tag and group value.
        static func decode(key: String) -> (tag: GroupTag, value: String)? {
            let parts = key.split(separator: "\u{1F}", maxSplits: 1)
            guard parts.count == 2,
                  let tag = GroupTag(rawValue: String(parts[0]))
            else { return nil }
            return (tag, String(parts[1]))
        }

        /// Collapses a raw tag into a group value, or `nil` if there is none.
        ///
        /// Case and surrounding whitespace are not meaningful in a tag value, and
        /// folding them is what stops "Rock", "rock" and " rock" becoming three
        /// albums with one member each. Interior whitespace is collapsed to single
        /// spaces for the same reason, and so that a newline can never appear
        /// inside a value — see `suppressionKey` for why that matters.
        static func normalized(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let collapsed = raw
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
            return collapsed.isEmpty ? nil : collapsed
        }
    }

    /// The short label shown under a derived album's name, from its `tagKey`.
    ///
    /// On the projector rather than on the model: the key is opaque by design, so
    /// nothing holding only a `Playlist` should be decoding it.
    static func descriptor(for key: String) -> String? {
        GroupTag.descriptor(for: key)
    }

    /// A group of tracks and the album that represents it.
    private struct Group {
        let tag: GroupTag
        /// Already normalised — the same string that goes into the key.
        let value: String
        var trackIDs: [UUID] = []
    }

    private let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    /// Brings every eligible derived album in line with the library's tags.
    ///
    /// Called after the tags it reads can have changed, never on a timer:
    /// `AudioManager` runs it after `LibraryTagSweep` has read the tags of files
    /// imported before tags existed, and once per completed import batch — so a
    /// 200-file import costs one projection, not 200.
    ///
    /// Saves once, at the end, and only if something changed. A launch where no
    /// group moved costs no write at all — worth the check, because a save mirrors
    /// the entire library and this runs on every launch.
    ///
    /// Returns the number of albums created, for logging. The membership of
    /// existing albums is changed in place and is not counted, because a number
    /// that changes every import is not worth logging.
    @discardableResult
    func run() -> Int {
        var changed = false
        var created = 0

        for tag in GroupTag.allCases {
            let result = project(tag)
            created += result.created
            changed = changed || result.changed
        }

        // Remove derived albums whose group is now empty. A suppressed group is
        // skipped rather than removed and recreated on the next launch: the user
        // deleted that album on purpose, and a resurrect-then-delete cycle would
        // make the Albums page flicker on every import.
        let suppressed = suppressedTags()
        let populated = populatedKeys(excluding: suppressed)

        for album in derivedAlbums() {
            guard let key = album.tagKey,
                  !populated.contains(key),
                  !suppressed.contains(key)
            else { continue }
            remove(album)
            changed = true
        }

        if created > 0 {
            Self.logger.notice("Created \(created) album(s) from library tags")
        }
        if changed {
            manager.playlistService.savePlaylists()
        }
        return created
    }

    /// One tag's worth of the projection.
    ///
    /// Create what is missing, then update membership. Matching an existing album
    /// is by `tagKey` and never by name, so a group whose album the user renamed
    /// is still found rather than duplicated.
    private func project(_ tag: GroupTag) -> (created: Int, changed: Bool) {
        let groups = group(tag, excluding: suppressedTags())
        var created = 0
        var changed = false

        for group in groups {
            let key = tag.key(for: group.value)

            if let index = manager.playlists.firstIndex(where: { $0.tagKey == key }) {
                changed = merge(group.trackIDs, into: manager.playlists[index]) || changed
                continue
            }

            // A hand-made album with this name is not adopted. Adopting it would
            // overwrite whatever the user put in it the first time a file with a
            // matching tag appeared — and "add the songs tagged Rock to my album
            // called Rock" is not what anyone asked for.
            let name = displayName(for: group)
            guard !manager.playlists.contains(where: { $0.isAlbum && $0.name == name }) else { continue }

            var album = Playlist(name: name, isAlbum: true, tagKey: key)
            album.audioFileIDs = group.trackIDs
            manager.playlists.append(album)
            created += 1
            changed = true
        }

        return (created, changed)
    }

    /// Every `tagKey` that currently has at least one file behind it, across all
    /// three tags and excluding suppressed groups.
    ///
    /// One pass over the library per tag rather than once per album: a derived
    /// album's emptiness is a question about the tags, and asking it by reading
    /// each album's membership back would be O(albums × library).
    private func populatedKeys(excluding suppressed: Set<String>) -> Set<String> {
        var keys: Set<String> = []

        for tag in GroupTag.allCases {
            for file in manager.audioFiles {
                guard let value = tag.value(for: file) else { continue }
                let key = tag.key(for: value)
                if !suppressed.contains(key) { keys.insert(key) }
            }
        }

        return keys
    }

    /// The groups this tag yields, in a stable order.
    ///
    /// Excludes suppressed values, and excludes any group with no files — an empty
    /// album is worse than a missing one, since the Albums page would show
    /// something the user cannot play. Ordering is by track count descending,
    /// then by value, so the order does not depend on dictionary iteration.
    private func group(_ tag: GroupTag, excluding suppressed: Set<String>) -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]

        for file in manager.audioFiles {
            guard let value = tag.value(for: file),
                  suppressed.contains(tag.key(for: value)) == false
            else { continue }

            if groups[value] == nil {
                groups[value] = Group(tag: tag, value: value)
                order.append(value)
            }
            groups[value]?.trackIDs.append(file.id)
        }

        return order.compactMap { groups[$0] }
            .sorted {
                $0.trackIDs.count != $1.trackIDs.count
                    ? $0.trackIDs.count > $1.trackIDs.count
                    : $0.value < $1.value
            }
    }

    /// Writes membership into an existing derived album without destroying the
    /// user's arrangement.
    ///
    /// Retained songs keep their relative order, including any the user has
    /// dragged around; genuinely new ones append. Songs the user removed, and
    /// songs whose tags changed, are gone from the group and so are dropped —
    /// a projection that let you remove a song from an album it defines by tag
    /// would be claiming a lie about the library.
    ///
    /// The album's own name is left alone: renaming a derived album is a
    /// reasonable thing to want and costs nothing to allow.
    @discardableResult
    private func merge(_ trackIDs: [UUID], into album: Playlist) -> Bool {
        guard let index = manager.playlists.firstIndex(where: { $0.id == album.id })
        else { return false }

        let members = manager.playlists[index].audioFileIDs
        let wanted = Set(trackIDs)

        var merged = members.filter { wanted.contains($0) }
        let present = Set(merged)
        merged.append(contentsOf: trackIDs.filter { !present.contains($0) })

        guard merged != members else { return false }
        manager.playlists[index].audioFileIDs = merged
        return true
    }

    /// The album's name: the group value, title-cased.
    ///
    /// Tags are conventionally written in one case and albums are conventionally
    /// written in another, and `rock` as an album name reads as a mistake. The
    /// value is already normalised for *comparison*, so this only changes the
    /// displayed form — the stored key keeps the folded value, which is why a
    /// rename here does not detach the album from its group.
    private func displayName(for group: Group) -> String {
        group.value.split(separator: " ").map { word in
            String(word.prefix(1)).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// The albums this projector owns: exactly those with a `tagKey`.
    ///
    /// Never derived from the name, and never from a list of tag values — both
    /// would eventually match a hand-made album.
    private func derivedAlbums() -> [Playlist] {
        manager.playlists.filter { $0.tagKey != nil }
    }

    private func remove(_ album: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == album.id }) else { return }
        manager.playlists.remove(at: index)
    }

    /// Records that the user does not want albums for a tag group.
    ///
    /// A statement about the *group* — "stop showing me a 'Jazz' album" — not about
    /// one album that happens to have that name.
    ///
    /// A future change to the tag's *meaning* lets the group come back: the value
    /// stored is the key, not a version counter, so a retag that genuinely alters
    /// the set is noticed by `group(_:)`, while a deletion is respected until the
    /// user asks again.
    /// Takes ownership of a derived album: it keeps its songs and becomes a normal
    /// hand-made album.
    ///
    /// Clearing `tagKey` is the whole mechanism. Every other rule in this type is
    /// expressed in terms of that field, so a null `tagKey` puts the album
    /// permanently outside the projector's reach — it will not be updated, will not
    /// be removed when its group empties, and will not have its songs pruned. No
    /// separate "detached" flag is needed or wanted: a second flag would be a
    /// second thing to get out of step.
    ///
    /// Also clears any suppression for the tag, so the album can be rebuilt from
    /// the tags again later if the user changes their mind. The two are opposite
    /// statements about the same group — "never show me this" and "this one is
    /// mine now" — and the second is the later one.
    static func detach(album: Playlist, from manager: AudioManager) {
        guard let key = album.tagKey,
              let index = manager.playlists.firstIndex(where: { $0.id == album.id })
        else { return }

        manager.playlists[index].tagKey = nil
        manager.playlistService.savePlaylists()
        unsuppress(key: key, in: manager)
    }

    /// Records that the user does not want albums for a tag group.
    ///
    /// Called when a derived album is deleted, which is the only way that can
    /// happen. A suppression outlives the album, survives a relaunch, and is keyed
    /// by the tag rather than the album's id, which is gone.
    static func suppress(key: String, in manager: AudioManager) {
        var keys = suppressedKeys(in: manager)
        keys.insert(key)

        let joined = keys.sorted().joined(separator: "\n")
        try? manager.libraryStore?.setMetaValue(joined, forKey: suppressionKey)
    }

    /// Undoes `suppress(key:in:)` for one tag group.
    private static func unsuppress(key: String, in manager: AudioManager) {
        var keys = suppressedKeys(in: manager)
        keys.remove(key)

        let joined = keys.isEmpty ? nil : keys.sorted().joined(separator: "\n")
        // A `nil` value deletes the row, so an empty set leaves no trace at all
        // rather than an empty string that `suppressedKeys` would have to treat as
        // a special case forever.
        try? manager.libraryStore?.setMetaValue(joined, forKey: suppressionKey)
    }

    /// `try?` on the *method call* flattens both failures into one `nil`:
    /// no store attached, and a read that threw. Both mean the same thing here —
    /// there is nothing recorded — so they are deliberately not told apart.
    private static func suppressedKeys(in manager: AudioManager) -> Set<String> {
        guard let raw = try? manager.libraryStore?.metaValue(forKey: suppressionKey),
              !raw.isEmpty
        else { return [] }

        return Set(raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// The tag keys the user has asked not to have albums for.
    ///
    /// Read on every projection rather than cached: a run may add entries, and a
    /// cached set would be stale by the end of the same run.
    private func suppressedTags() -> Set<String> {
        Self.suppressedKeys(in: manager)
    }
}
