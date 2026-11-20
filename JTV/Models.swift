import Foundation

// MARK: - Plugin source manifest (plugins.json)

struct PluginManifestFile: Codable {
    var version: Int = 1
    var plugins: [PluginManifest] = []

    enum CodingKeys: String, CodingKey { case version, plugins }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        plugins = try c.decodeIfPresent([PluginManifest].self, forKey: .plugins) ?? []
    }
}

/// One plugin entry. Used both for the remote plugins.json entries
/// (id/name/version/scriptUrl/iconUrl) and for the manifest a plugin
/// script returns from getManifest() (baseUrl/isEnabled/type...).
struct PluginManifest: Codable, Identifiable, Hashable {
    var id: String = ""
    var name: String = ""
    var version: String = ""
    var scriptUrl: String = ""
    var iconUrl: String = ""
    var baseUrl: String = ""
    var isEnabled: Bool = true
    var type: String = "MOVIE"
    var playerType: String = ""
    /// Set from the plugins.json entry (scripts don't declare it): keeps
    /// the 18+ gate correct even for plugins added remotely later.
    var adult: Bool = false
    /// Declared by the plugin script's getManifest(): the longest
    /// embed chain this plugin's protocol needs the resolver to
    /// follow. 0 = no declaration.
    var maxChainParses: Int = 0

    var isManga: Bool { type.uppercased() == "MANGA" }
    var isEmbedPlayer: Bool { playerType.lowercased() == "embed" }

    enum CodingKeys: String, CodingKey {
        case id, name, version, scriptUrl, iconUrl, baseUrl, isEnabled, type, playerType, adult, maxChainParses
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        scriptUrl = try c.decodeIfPresent(String.self, forKey: .scriptUrl) ?? ""
        iconUrl = try c.decodeIfPresent(String.self, forKey: .iconUrl) ?? ""
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "MOVIE"
        playerType = try c.decodeIfPresent(String.self, forKey: .playerType) ?? ""
        adult = try c.decodeIfPresent(Bool.self, forKey: .adult) ?? false
        maxChainParses = try c.decodeIfPresent(Int.self, forKey: .maxChainParses) ?? 0
    }
}

// MARK: - Plugin runtime values

struct HomeSection: Codable, Identifiable, Hashable {
    var slug: String = ""
    var title: String = ""
    var type: String = "Horizontal"   // "Horizontal" | "Grid"
    var path: String = ""

    var id: String { slug + "|" + title }
    var isGrid: Bool { type.lowercased() == "grid" }

    enum CodingKeys: String, CodingKey { case slug, title, type, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Horizontal"
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

struct NameSlug: Codable, Identifiable, Hashable {
    var name: String = ""
    var slug: String = ""
    var id: String { slug.isEmpty ? name : slug }

    enum CodingKeys: String, CodingKey { case name, slug }

    init(name: String = "", slug: String = "") { self.name = name; self.slug = slug }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
    }
}

struct NameValue: Codable, Identifiable, Hashable {
    var name: String = ""
    var value: String = ""
    var id: String { value.isEmpty ? name : value }

    enum CodingKeys: String, CodingKey { case name, value, slug }

    init(name: String = "", value: String = "") { self.name = name; self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let v = try c.decodeIfPresent(String.self, forKey: .value) {
            value = v
        } else {
            value = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(value, forKey: .value)
    }
}

/// getFilterConfig() result: a "sort" group plus any other groups the
/// plugin defines (e.g. "category"). Decoded tolerantly.
struct FilterConfig {
    var sort: [NameValue] = []
    var groups: [String: [NameValue]] = [:]   // group key -> options (excluding "sort")

    /// Ordered group keys for display: sort first, then the rest alphabetically.
    var orderedKeys: [String] {
        var keys: [String] = []
        if !sort.isEmpty { keys.append("sort") }
        keys.append(contentsOf: groups.keys.sorted())
        return keys
    }

    func options(for key: String) -> [NameValue] {
        if key == "sort" { return sort }
        return groups[key] ?? []
    }

    static func decode(from data: Data) -> FilterConfig {
        var config = FilterConfig()
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return config }
        func parseOptions(_ raw: Any?) -> [NameValue] {
            guard let arr = raw as? [[String: Any]] else { return [] }
            return arr.compactMap { item in
                let name = item["name"] as? String ?? ""
                let value = (item["value"] as? String) ?? (item["slug"] as? String) ?? ""
                if name.isEmpty && value.isEmpty { return nil }
                return NameValue(name: name.isEmpty ? value : name, value: value)
            }
        }
        for (key, raw) in dict {
            let opts = parseOptions(raw)
            if opts.isEmpty { continue }
            if key == "sort" { config.sort = opts } else { config.groups[key] = opts }
        }
        return config
    }
}

/// Active list filters (encoded into the filtersJson passed to plugins).
struct ListFilters: Equatable, Hashable {
    var category: String = ""
    var country: String = ""
    var year: String = ""
    var sort: String = ""
    /// Extra groups coming from getFilterConfig() (key -> selected value).
    var extra: [String: String] = [:]

    var isEmpty: Bool {
        category.isEmpty && country.isEmpty && year.isEmpty && sort.isEmpty
            && extra.values.allSatisfy { $0.isEmpty }
    }

    mutating func set(_ key: String, value: String) {
        switch key {
        case "category": category = value
        case "country": country = value
        case "year": year = value
        case "sort": sort = value
        default: extra[key] = value
        }
    }

    func value(for key: String) -> String {
        switch key {
        case "category": return category
        case "country": return country
        case "year": return year
        case "sort": return sort
        default: return extra[key] ?? ""
        }
    }

    func jsonString(page: Int, limit: Int = 24) -> String {
        var dict: [String: Any] = ["page": page, "limit": limit]
        if !category.isEmpty { dict["category"] = category }
        if !country.isEmpty { dict["country"] = country }
        if !year.isEmpty { dict["year"] = year }
        if !sort.isEmpty { dict["sort"] = sort }
        for (k, v) in extra where !v.isEmpty { dict[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Movies

struct Movie: Codable, Identifiable, Hashable {
    var id: String = ""                 // slug within its plugin
    var title: String = ""
    var posterUrl: String = ""
    var backdropUrl: String = ""
    var year: Int = 0
    var quality: String = ""
    var episode_current: String = ""
    var lang: String = ""

    enum CodingKeys: String, CodingKey {
        case id, title, posterUrl, backdropUrl, year, quality, episode_current, lang
    }

    init() {}

    init(id: String, title: String, posterUrl: String = "", backdropUrl: String = "",
         year: Int = 0, quality: String = "", episode_current: String = "", lang: String = "") {
        self.id = id; self.title = title; self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl; self.year = year; self.quality = quality
        self.episode_current = episode_current; self.lang = lang
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl) ?? ""
        backdropUrl = try c.decodeIfPresent(String.self, forKey: .backdropUrl) ?? ""
        if let y = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = y ?? 0
        } else if let ys = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = Int(ys ?? "") ?? 0
        } else {
            year = 0
        }
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? ""
        episode_current = try c.decodeIfPresent(String.self, forKey: .episode_current) ?? ""
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? ""
    }

    var displayBackdrop: String { backdropUrl.isEmpty ? posterUrl : backdropUrl }
}

struct Pagination: Codable {
    var currentPage: Int = 1
    var totalPages: Int = 1
    var totalItems: Int = 0
    var itemsPerPage: Int = 24

    enum CodingKeys: String, CodingKey { case currentPage, totalPages, totalItems, itemsPerPage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = try c.decodeIfPresent(Int.self, forKey: .currentPage) ?? 1
        totalPages = try c.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
        totalItems = try c.decodeIfPresent(Int.self, forKey: .totalItems) ?? 0
        itemsPerPage = try c.decodeIfPresent(Int.self, forKey: .itemsPerPage) ?? 24
    }

    init(currentPage: Int = 1, totalPages: Int = 1, totalItems: Int = 0, itemsPerPage: Int = 24) {
        self.currentPage = currentPage; self.totalPages = totalPages
        self.totalItems = totalItems; self.itemsPerPage = itemsPerPage
    }
}

struct ListPage: Codable {
    var items: [Movie] = []
    var pagination: Pagination = Pagination()

    enum CodingKeys: String, CodingKey { case items, pagination }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Movie].self, forKey: .items) ?? []
        pagination = try c.decodeIfPresent(Pagination.self, forKey: .pagination) ?? Pagination()
    }

    init(items: [Movie] = [], pagination: Pagination = Pagination()) {
        self.items = items; self.pagination = pagination
    }
}

struct Episode: Codable, Identifiable, Hashable {
    var id: String = ""       // play target: direct media URL, embed URL, or chapter API URL
    var name: String = ""
    var slug: String = ""

    enum CodingKeys: String, CodingKey { case id, name, slug }

    init(id: String = "", name: String = "", slug: String = "") {
        self.id = id; self.name = name; self.slug = slug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
    }
}

struct EpisodeServer: Codable, Identifiable, Hashable {
    var name: String = ""
    var episodes: [Episode] = []
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, episodes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        episodes = try c.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
    }

    init(name: String = "", episodes: [Episode] = []) {
        self.name = name; self.episodes = episodes
    }
}

struct MovieDetail: Codable {
    var id: String = ""
    var title: String = ""
    var originName: String = ""
    var posterUrl: String = ""
    var backdropUrl: String = ""
    var description: String = ""
    var year: Int = 0
    var rating: Double = 0
    var quality: String = ""
    var servers: [EpisodeServer] = []
    var episode_current: String = ""
    var lang: String = ""
    var category: String = ""
    var country: String = ""
    var director: String = ""
    var casts: String = ""
    var tmdbId: String = ""
    var tmdbSeason: Int = 0
    var tmdbType: String = ""

    enum CodingKeys: String, CodingKey {
        case id, title, originName, posterUrl, backdropUrl, description, year, rating,
             quality, servers, episode_current, lang, category, country, director, casts,
             tmdbId, tmdbSeason, tmdbType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        originName = try c.decodeIfPresent(String.self, forKey: .originName) ?? ""
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl) ?? ""
        backdropUrl = try c.decodeIfPresent(String.self, forKey: .backdropUrl) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        if let y = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = y ?? 0
        } else if let ys = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = Int(ys ?? "") ?? 0
        } else { year = 0 }
        if let r = try? c.decodeIfPresent(Double.self, forKey: .rating) {
            rating = r ?? 0
        } else if let rs = try? c.decodeIfPresent(String.self, forKey: .rating) {
            rating = Double(rs ?? "") ?? 0
        } else { rating = 0 }
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? ""
        servers = try c.decodeIfPresent([EpisodeServer].self, forKey: .servers) ?? []
        episode_current = try c.decodeIfPresent(String.self, forKey: .episode_current) ?? ""
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        director = try c.decodeIfPresent(String.self, forKey: .director) ?? ""
        casts = try c.decodeIfPresent(String.self, forKey: .casts) ?? ""
        if let t = try? c.decodeIfPresent(String.self, forKey: .tmdbId) {
            tmdbId = t ?? ""
        } else if let ti = try? c.decodeIfPresent(Int.self, forKey: .tmdbId) {
            tmdbId = String(ti)
        } else { tmdbId = "" }
        tmdbSeason = try c.decodeIfPresent(Int.self, forKey: .tmdbSeason) ?? 0
        tmdbType = try c.decodeIfPresent(String.self, forKey: .tmdbType) ?? ""
    }

    /// Movie snapshot for navigation / favorites.
    var asMovie: Movie {
        Movie(id: id, title: title, posterUrl: posterUrl, backdropUrl: backdropUrl,
              year: year, quality: quality, episode_current: episode_current, lang: lang)
    }

    var castNames: [String] {
        casts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Streaming

struct SubtitleTrack: Codable, Hashable {
    var lang: String = ""
    var url: String = ""
    var label: String = ""

    enum CodingKeys: String, CodingKey { case lang, url, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    init(lang: String = "", url: String = "", label: String = "") {
        self.lang = lang; self.url = url; self.label = label
    }

    var displayName: String {
        if !label.isEmpty { return label }
        if !lang.isEmpty { return lang }
        return "Phụ đề"
    }
}

/// Result of parseDetailResponse / parseEmbedResponse.
struct StreamInfo: Codable {
    var url: String = ""
    var headers: [String: String] = [:]
    var subtitles: [SubtitleTrack] = []
    var images: [String] = []
    var isEmbed: Bool = false
    /// Form body for POST-config hops (e.g. vlxx's ajax player call).
    var postBody: String? = nil
    /// Start playback through the HLS rescue proxy immediately
    /// (the playlist's segments sit behind a dead proxy host — see
    /// MovieService.markProxyIfNeeded). Set by the app only;
    /// plugin payloads decode it as false.
    var requiresProxy: Bool = false
    /// Play this stream on the KSPlayer (FFmpeg) surface instead of
    /// AVPlayer — set by the app only: by DebridResolver when the
    /// resolved file's container is one AVFoundation cannot open
    /// (MKV/AVI/…). Plugin payloads decode it as false.
    var useCompatEngine: Bool = false

    enum CodingKeys: String, CodingKey { case url, headers, subtitles, images, isEmbed, postBody, requiresProxy, useCompatEngine }

    init(url: String = "", headers: [String: String] = [:],
         subtitles: [SubtitleTrack] = [], images: [String] = [], isEmbed: Bool = false,
         postBody: String? = nil, requiresProxy: Bool = false, useCompatEngine: Bool = false) {
        self.url = url; self.headers = headers; self.subtitles = subtitles
        self.images = images; self.isEmbed = isEmbed; self.postBody = postBody
        self.requiresProxy = requiresProxy; self.useCompatEngine = useCompatEngine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        subtitles = try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles) ?? []
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        isEmbed = try c.decodeIfPresent(Bool.self, forKey: .isEmbed) ?? false
        postBody = try c.decodeIfPresent(String.self, forKey: .postBody) ?? nil
        requiresProxy = try c.decodeIfPresent(Bool.self, forKey: .requiresProxy) ?? false
        useCompatEngine = try c.decodeIfPresent(Bool.self, forKey: .useCompatEngine) ?? false
    }

    var streamURL: URL? { url.isEmpty ? nil : URL(string: url) }
    var hasPlayableURL: Bool { !url.isEmpty }
}

/// What the playback resolver decided an episode tap should open.
enum PlaybackResolution {
    case video(StreamInfo)
    case manga(StreamInfo)
    /// `sniffMedia` false means the page IS the player (the
    /// operator's own player page): the webview must be left
    /// alone to play in-page, with no media sniffing — sniffing
    /// would capture the page's internal stream URL and promote
    /// it to a native surface, defeating the hand-off. Only the
    /// streamxx fallback passes false; every other embed sniffs.
    case embed(url: URL, headers: [String: String], sniffMedia: Bool)
}

/// Everything needed to start (or resume) playback of one episode/chapter.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    var movie: Movie
    var pluginId: String
    var pluginName: String = ""
    var isManga: Bool = false
    var serverName: String = ""
    var episode: Episode
    var allEpisodes: [Episode] = []
    var startPosition: Double = 0
    /// Last known direct stream URL from a history record (fast resume path).
    var knownStreamURL: String = ""
    var fallbackHeaders: [String: String] = [:]
    /// v1.22.5: the curated top-5 source shortlist for the
    /// in-player switcher (torrent titles; built by DetailView
    /// across ALL of the detail's servers). Empty = fall back to
    /// allEpisodes.
    var switchList: [Episode] = []
}

/// Navigation route to a movie detail screen (carries its plugin).
struct MovieRoute: Hashable {
    var pluginId: String
    var movie: Movie
    /// Set when the route comes from Continue Watching: the
    /// detail screen replays the saved progress once loaded,
    /// so closing the player lands back on the detail screen
    /// (where another chapter can be picked) instead of
    /// dropping the user at the library list.
    var autoResume: Bool = false
}

/// Navigation route to a category listing screen.
struct CategoryRoute: Hashable {
    let pluginId: String
    let slug: String
    let title: String
    let filters: ListFilters
}

/// Navigation route to a search-results screen (cast taps).
struct SearchRoute: Hashable {
    let pluginId: String
    let keyword: String
}

/// The single route type every browsing stack (Home / Categories /
/// Search / Library) is built on, so each stack's path is explicit
/// state the app owns instead of SwiftUI's opaque internal store.
enum AppRoute: Hashable {
    case movie(MovieRoute)
    case category(CategoryRoute)
    case search(SearchRoute)
}

/// Guards the browsing stacks against a navigation race: a push
/// that lands while a pop transition is still running can stack
/// the new detail page ON TOP of the detail that was on its way
/// out, so Back then walks through stale detail pages instead of
/// returning to the list (the sextop1 browsing bug, 2026-11-14).
/// After every path change, collapse any run of adjacent movie
/// routes to the newest one and drop exact duplicates. No
/// legitimate flow places two movie details adjacent — getting
/// from one detail to another always passes through a list or a
/// search-results page — so collapsing is always safe.
enum NavSanitizer {
    static func sanitize(_ path: inout [AppRoute]) {
        var cleaned: [AppRoute] = []
        cleaned.reserveCapacity(path.count)
        for route in path {
            if let last = cleaned.last {
                if case .movie = route, case .movie = last {
                    cleaned[cleaned.count - 1] = route
                    continue
                }
                if route == last { continue }
            }
            cleaned.append(route)
        }
        if cleaned != path { path = cleaned }
    }
}

// MARK: - URL helpers

enum MediaURL {
    static func isDirectMedia(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.hasPrefix("http") else { return false }
        let path = lower.split(separator: "?").first.map(String.init) ?? lower
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".m4v")
            || path.hasSuffix(".mov") || path.hasSuffix(".mpd") || path.hasSuffix(".ts")
    }

    static func isWebPage(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("http") && !isDirectMedia(lower)
    }
}
