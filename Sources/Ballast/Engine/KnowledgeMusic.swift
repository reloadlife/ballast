import Foundation

/// Music and audio: the Music library, Podcasts, GarageBand and Logic Pro
/// sound libraries, Spotify, Ableton Live.
enum KnowledgeMusic {
    private static let music = "com.apple.Music"
    private static let ableton = ["com.ableton.live"]

    static let entries: [KnowledgeEntry] = [
        // MARK: Music
        KnowledgeEntry(
            id: "music.library-folder", name: "Your Music library", pathPattern: "Music/Music", owners: [music],
            kind: .userData, verdict: .blocked,
            regenerates: "The library Music uses, with the songs you added. Removing it empties Music.",
            guidance: "Manage songs in the Music app. To move the library, use Music › Settings › Files."
        ),
        KnowledgeEntry(
            id: "music.library-database", name: "The Music library database",
            pathPattern: "Music/Music/Music Library.musiclibrary", owners: [music], kind: .userData, verdict: .blocked,
            regenerates: "Your playlists, ratings, play counts and the list of songs. Removing it empties your library.",
            guidance: "To keep a copy or move it, use Music › Settings › Files."
        ),
        KnowledgeEntry(
            id: "music.media", name: "Songs in your Music library", pathPattern: "Music/Music/Media*", owners: [music],
            kind: .userData, verdict: .caution,
            regenerates: "Songs, videos and podcasts the library holds. What you imported yourself is gone for good once removed.",
            guidance: "Delete songs in the Music app so the library stays in step."
        ),
        KnowledgeEntry(
            id: "music.apple-music-downloads", name: "Apple Music downloads",
            pathPattern: "Music/Music/Media*/Apple Music", owners: [music], kind: .download, verdict: .caution,
            regenerates: "Songs downloaded from Apple Music to play offline. They stay in your library and download again while you subscribe.",
            guidance: "Remove them from Music to keep your library tidy: select the songs, then Song › Remove Download."
        ),
        KnowledgeEntry(
            id: "music.itunes-folder", name: "An iTunes library folder", pathPattern: "Music/iTunes", owners: [music],
            kind: .userData, verdict: .caution,
            regenerates: "Left from iTunes, or still in use if Music was pointed at it. Check it holds nothing you need.",
            guidance: "Music › Settings › Files shows which library folder Music uses."
        ),
        KnowledgeEntry(
            id: "music.itunes-media", name: "Songs in an iTunes library", pathPattern: "Music/iTunes/iTunes Media",
            owners: [music], kind: .userData, verdict: .caution,
            regenerates: "Songs, videos and podcasts from an iTunes library. What you imported yourself is gone for good once removed.",
            guidance: "Music › Settings › Files shows which library folder Music uses."
        ),
        KnowledgeEntry(
            id: "music.previous-libraries", name: "Previous iTunes libraries",
            pathPattern: "Music/iTunes/Previous iTunes Libraries", kind: .backup, verdict: .safe, action: .remove,
            regenerates: "Copies iTunes made of its library database before upgrades. Music doesn't use them."
        ),
        KnowledgeEntry(
            id: "music.album-artwork-cache", name: "Album artwork cache", pathPattern: "Music/iTunes/Album Artwork/Cache",
            owners: [music], kind: .cache, verdict: .safe, action: .remove,
            regenerates: "Thumbnails of album covers. Music draws them again."
        ),
        KnowledgeEntry(
            id: "music.caches", name: "Music's cache", pathPattern: "Library/Caches/com.apple.Music", owners: [music],
            kind: .cache, verdict: .quitFirst, action: .remove,
            regenerates: "Artwork and streaming data Music keeps. It fills again as you browse and play."
        ),
        KnowledgeEntry(
            id: "music.artwork-agent-cache", name: "Music artwork cache",
            pathPattern: "Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches", owners: [music],
            kind: .cache, verdict: .quitFirst, action: .remove,
            regenerates: "Album art for Music and the TV app. Fetched again when shown."
        ),
        KnowledgeEntry(
            id: "music.library-agent-cache", name: "Music library helper cache",
            pathPattern: "Library/Containers/com.apple.AMPLibraryAgent/Data/Library/Caches", owners: [music],
            kind: .cache, verdict: .quitFirst, action: .remove,
            regenerates: "Kept by the helper that syncs your library. It rebuilds it."
        ),

        // MARK: Podcasts
        KnowledgeEntry(
            id: "podcasts.library", name: "Podcasts downloads and library",
            pathPattern: "Library/Group Containers/243LU875E5.groups.com.apple.podcasts", owners: ["com.apple.podcasts"],
            kind: .download, verdict: .caution,
            regenerates: "Episodes you downloaded and the Podcasts library. Episodes download again; your shows sync through iCloud.",
            guidance: "In Podcasts › Settings, turn on Remove Played Downloads, or remove episodes from a show's page."
        ),

        // MARK: GarageBand and Logic Pro
        KnowledgeEntry(
            id: "audio.garageband-sounds", name: "GarageBand's sound library",
            pathPattern: "/Library/Application Support/GarageBand", owners: ["com.apple.garageband10"],
            kind: .download, verdict: .caution, action: .remove,
            regenerates: "Instruments and loops GarageBand downloaded. Projects that use them play without those sounds until you download them again.",
            guidance: "Reinstall via Sound Library: GarageBand › Sound Library › Download All Available Sounds."
        ),
        KnowledgeEntry(
            id: "audio.logic-sounds", name: "Logic Pro's sound library",
            pathPattern: "/Library/Application Support/Logic", owners: ["com.apple.logic10"],
            kind: .download, verdict: .caution, action: .remove,
            regenerates: "Instruments, samples and loops Logic Pro downloaded. Projects that use them play without those sounds until you download them again.",
            guidance: "Reinstall via Sound Library: Logic Pro › Sound Library › Open Sound Library Manager."
        ),
        KnowledgeEntry(
            id: "audio.apple-loops", name: "Apple Loops", pathPattern: "/Library/Audio/Apple Loops",
            owners: ["com.apple.garageband10", "com.apple.logic10"], kind: .download, verdict: .caution, action: .remove,
            regenerates: "Loops GarageBand and Logic Pro share. Projects that use them play without them until you download them again.",
            guidance: "Reinstall via Sound Library in GarageBand or Logic Pro."
        ),
        KnowledgeEntry(
            id: "audio.music-apps", name: "GarageBand and Logic Pro content", pathPattern: "Music/Audio Music Apps",
            owners: ["com.apple.garageband10", "com.apple.logic10"], kind: .userData, verdict: .caution,
            regenerates: "Downloaded sound packs plus your own patches, presets and channel strips. Downloads come back from Sound Library; your own presets don't."
        ),

        // MARK: Spotify
        KnowledgeEntry(
            id: "spotify.cache", name: "Spotify's cache", pathPattern: "Library/Caches/com.spotify.client",
            owners: ["com.spotify.client"], kind: .cache, verdict: .quitFirst, action: .remove,
            regenerates: "Spotify fills it again as you listen."
        ),
        KnowledgeEntry(
            id: "spotify.storage", name: "Spotify's offline storage",
            pathPattern: "Library/Application Support/Spotify/PersistentCache", owners: ["com.spotify.client"],
            kind: .download, verdict: .caution,
            regenerates: "Spotify's streaming cache together with the songs and podcasts you downloaded. Downloads have to be fetched again.",
            guidance: "Spotify › Settings › Storage clears the cache without touching downloads."
        ),
        KnowledgeEntry(
            id: "spotify.data", name: "Spotify's data", pathPattern: "Library/Application Support/Spotify",
            owners: ["com.spotify.client"], kind: .appSupport, verdict: .blocked,
            regenerates: "Your Spotify sign-in and settings.",
            guidance: "Spotify › Settings › Storage clears the cache and downloads."
        ),

        // MARK: Ableton Live
        KnowledgeEntry(
            id: "ableton.library", name: "Ableton Live's library", pathPattern: "Music/Ableton", owners: ableton,
            kind: .userData, verdict: .caution,
            regenerates: "Packs you installed plus your own presets, samples and recordings. Packs install again from Live's browser; your own files don't.",
            guidance: "Remove Packs from Live's browser under Packs."
        ),
        KnowledgeEntry(
            id: "ableton.cache", name: "Ableton Live's decoding cache", pathPattern: "Library/Caches/Ableton", owners: ableton,
            kind: .cache, verdict: .quitFirst, action: .remove,
            regenerates: "Decoded copies of compressed samples. Live makes them again when they play.",
            guidance: "Live › Settings › File & Folder › Decoding Cache › Clean Up does the same."
        ),
        KnowledgeEntry(
            id: "ableton.database", name: "Ableton Live's browser index",
            pathPattern: "Library/Application Support/Ableton/Live Database", owners: ableton, kind: .cache, verdict: .quitFirst, action: .remove,
            regenerates: "Live rebuilds it the next time it starts, which can take a while."
        ),
        KnowledgeEntry(
            id: "ableton.data", name: "Ableton Live's settings", pathPattern: "Library/Application Support/Ableton", owners: ableton,
            kind: .appSupport, verdict: .blocked,
            regenerates: "Your Live preferences, authorization and templates."
        ),
    ]
}
