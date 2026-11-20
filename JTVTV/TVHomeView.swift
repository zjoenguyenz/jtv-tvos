import SwiftUI

/// JTV tvOS Phase 2 — Home: the pinned plugin chip rail, the
/// hero, Continue Watching, and one band per plugin section —
/// the iOS HomeView structure (survey §1.1) rebuilt on the
/// Phase 2 focus template (plan §3/§4.1). Sections data lives in
/// TVHomeStore, published once at load (FL-017/222); the same
/// store feeds Search's on-device pool.

// MARK: - Home store

@MainActor
@Observable
final class TVHomeStore {
    private(set) var sections: [HomeSection] = []
    private(set) var items: [String: [Movie]] = [:]
    private(set) var sectionErrors: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var loadedPluginId: String?

    private var loadedAt: Date?
    private var generation = 0

    /// The iOS hero rule: first movie, in section order, whose
    /// displayBackdrop is non-empty.
    var heroMovie: Movie? {
        for section in sections {
            if let movie = items[section.id]?.first(where: { !$0.displayBackdrop.isEmpty }) {
                return movie
            }
        }
        return nil
    }

    /// Every loaded movie for the currently loaded plugin,
    /// deduped by id — Search's on-device pool (JoeTV mechanism:
    /// paint instantly from what the device already holds).
    func pool(for pluginId: String) -> [Movie] {
        guard loadedPluginId == pluginId else { return [] }
        var seen = Set<String>()
        var out: [Movie] = []
        for section in sections {
            for movie in items[section.id] ?? [] where seen.insert(movie.id).inserted {
                out.append(movie)
            }
        }
        return out
    }

    func load(plugins: PluginManager, service: MovieService, force: Bool = false) async {
        guard let pid = plugins.activePlugin?.id else {
            sections = []
            items = [:]
            sectionErrors = [:]
            loadedPluginId = nil
            loadedAt = nil
            return
        }
        if !force, loadedPluginId == pid, let loadedAt,
           Date().timeIntervalSince(loadedAt) < 600 {
            return
        }
        generation += 1
        let gen = generation
        isLoading = true
        let secs = await service.homeSections(pluginId: pid)
        guard gen == generation else { return }
        sections = secs
        loadedPluginId = pid
        loadedAt = Date()
        if secs.isEmpty {
            isLoading = false
            return
        }
        // Per-section page-1 fetches in parallel; each row
        // publishes as its own fetch lands (the iOS shape).
        await withTaskGroup(of: (String, Result<[Movie], Error>).self) { group in
            for section in secs {
                group.addTask {
                    do {
                        let page = try await service.list(pluginId: pid, slug: section.slug,
                                                          filters: ListFilters(), page: 1)
                        return (section.id, .success(page.items))
                    } catch {
                        return (section.id, .failure(error))
                    }
                }
            }
            for await (sectionId, result) in group {
                guard gen == self.generation else { continue }
                switch result {
                case .success(let movies):
                    items[sectionId] = movies
                    sectionErrors[sectionId] = nil
                    if !movies.isEmpty {
                        ImageCacheManager.shared.prefetch(urlStrings: movies.map(\.posterUrl))
                    }
                case .failure(let error):
                    // Per-section errors publish per section,
                    // never swallowed (FL-005/246).
                    if items[sectionId] == nil { items[sectionId] = [] }
                    sectionErrors[sectionId] = "Không tải được mục này"
                    DiagLog.log("home", "section failed plugin=\(pid) section=\(sectionId) kind=\((error as NSError).domain)#\((error as NSError).code)")
                }
            }
        }
        if gen == generation { isLoading = false }
    }
}

// MARK: - Home view

struct TVHomeView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var session: PinSession
    @Environment(TVHomeStore.self) private var store
    @Environment(TVNavPath.self) private var nav
    @Environment(\.tvTheme) private var theme

    @Namespace private var focusNS

    var body: some View {
        VStack(spacing: 0) {
            if plugins.visiblePlugins.isEmpty {
                TVEmptyState(icon: "puzzlepiece.extension",
                             title: "Chưa có nguồn plugin",
                             actionTitle: "Đồng bộ ngay") {
                    Task { await plugins.syncAll() }
                }
            } else {
                chipRail
                content
            }
        }
        .tvThemedBackground()
        .focusScope(focusNS)
        .onAppear { session.touch() }
        .task {
            if plugins.installed.isEmpty {
                await plugins.syncAll()
            } else {
                Task { await plugins.syncAll(silent: true) }
            }
            await store.load(plugins: plugins, service: service)
        }
        .onChange(of: plugins.activePluginId) { _, _ in
            Task { await store.load(plugins: plugins, service: service) }
        }
        .onChange(of: plugins.syncGeneration) { _, _ in
            Task { await store.load(plugins: plugins, service: service) }
        }
    }

    // The plugin switcher is pinned OUTSIDE the scroll region
    // (iOS rule — nested scrolls competed for the gesture).
    private var chipRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(plugins.visiblePlugins) { plugin in
                    TVChip(title: plugin.manifest.name,
                           iconURL: plugin.manifest.iconUrl,
                           badge18: plugins.isAdult(plugin.id),
                           selected: plugin.id == plugins.activePluginId) {
                        plugins.activePluginId = plugin.id
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 18)
        }
        .focusSection()
        .prefersDefaultFocus(true, in: focusNS)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                if let hero = store.heroMovie, let pid = plugins.activePlugin?.id {
                    heroBand(hero: hero, pluginId: pid)
                        .focusSection()
                }
                if !history.continueWatching.isEmpty {
                    continueWatchingBand
                        .focusSection()
                }
                ForEach(store.sections) { section in
                    sectionBand(section)
                        .focusSection()
                }
                if store.isLoading && store.sections.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 48)
        }
    }

    private func heroBand(hero: Movie, pluginId: String) -> some View {
        TVHeroCard(movie: hero) {
            nav.push(.movie(MovieRoute(pluginId: pluginId, movie: hero, autoResume: false)))
        }
    }

    private var continueWatchingBand: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: "Đang xem tiếp")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(history.continueWatching) { record in
                        TVLandscapeCard(record: record, width: 400,
                                        onSelect: {
                                            nav.push(.movie(MovieRoute(pluginId: record.pluginId,
                                                                       movie: record.movie,
                                                                       autoResume: true)))
                                        },
                                        onLongPress: {
                                            history.remove(record)
                                        })
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func sectionBand(_ section: HomeSection) -> some View {
        let movies = store.items[section.id] ?? []
        if let error = store.sectionErrors[section.id], movies.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TVSectionHeader(title: section.title)
                TVSectionErrorRow(message: error) {
                    Task { await store.load(plugins: plugins, service: service, force: true) }
                }
            }
        } else if !movies.isEmpty, let pid = plugins.activePlugin?.id {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader(title: section.title) {
                    nav.push(.category(CategoryRoute(pluginId: pid, slug: section.slug,
                                                     title: section.title, filters: ListFilters())))
                }
                if section.isGrid {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 24), count: 6),
                              spacing: 30) {
                        ForEach(Array(movies.prefix(9))) { movie in
                            TVGridPosterCell(movie: movie, width: 250,
                                             isFavorite: favorites.isFavorite(pluginId: pid, movieId: movie.id),
                                             onSelect: {
                                                 nav.push(.movie(MovieRoute(pluginId: pid, movie: movie)))
                                             },
                                             onLongPress: {
                                                 favorites.toggle(pluginId: pid, movie: movie)
                                             })
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 24) {
                            ForEach(movies) { movie in
                                TVPosterCard(movie: movie, width: 240,
                                             isFavorite: favorites.isFavorite(pluginId: pid, movieId: movie.id),
                                             onSelect: {
                                                 nav.push(.movie(MovieRoute(pluginId: pid, movie: movie)))
                                             },
                                             onLongPress: {
                                                 favorites.toggle(pluginId: pid, movie: movie)
                                             })
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Section error row

/// A failed section's visible error surface (FL-005/246): the
/// message plus a focusable retry with a proper inset ring.
private struct TVSectionErrorRow: View {
    let message: String
    let onRetry: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var retryFocused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.badgeQuality)
            Text(message)
                .font(.system(size: 24))
                .foregroundStyle(theme.textDim)
            Button {
                onRetry()
            } label: {
                Text("Thử lại")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(retryFocused ? theme.focusRing : .clear,
                                                    lineWidth: retryFocused ? theme.ringWidth : 0))
            }
            .tvCardButton()
            .focused($retryFocused)
        }
    }
}

// MARK: - Hero card

/// The Home hero (mockup 01): the featured title's backdrop at
/// bucket 1920, quality badge, title + meta over a bottom fade,
/// and a radius-matched inset focus ring on the same rect.
private struct TVHeroCard: View {
    let movie: Movie
    let onSelect: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    private let radius: CGFloat = 22

    var body: some View {
        Button {
            onSelect()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.cardFill)
                TVRemoteImage(urlString: movie.displayBackdrop, bucket: 1920)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: Color.black.opacity(0.82), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                VStack {
                    HStack {
                        if !movie.quality.isEmpty {
                            Text(movie.quality)
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.badgeQuality))
                        }
                        Spacer()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(movie.title)
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        HStack(spacing: 12) {
                            if movie.year > 0 { Text(String(movie.year)) }
                            if !movie.episode_current.isEmpty {
                                Text("•")
                                Text(movie.episode_current)
                            }
                            if !movie.lang.isEmpty {
                                Text("•")
                                Text(movie.lang)
                            }
                        }
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.78))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(30)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 440)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.08 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isFocused ? theme.focusRing : .clear,
                                  lineWidth: isFocused ? theme.ringWidth : 0)
            }
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
    }
}
