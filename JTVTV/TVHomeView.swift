import SwiftUI
import UIKit

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
    private(set) var didLoad = false
    /// The iOS hero rule, computed ONCE at the end of load()
    /// from the final sections/items: first movie, in section
    /// order, whose displayBackdrop is non-empty.
    private(set) var heroMovie: Movie?
    /// L-T42 (1.3.16): per-section rail paging state —
    /// the view-owned page counter per FL-489 (the
    /// REQUESTED page; the parser's pagination.currentPage
    /// never overwrites it), the adopted total, and the
    /// finished set (a page adding zero new items after
    /// dedupe, or an empty page 1, ends paging for that
    /// section). Instance state only (FL-495).
    private(set) var sectionPages: [String: Int] = [:]
    private(set) var sectionTotalPages: [String: Int] = [:]
    private(set) var sectionFinished: Set<String> = []
    /// In-flight rail appends, tokenised: sectionId → the
    /// store generation captured by the attempt that owns
    /// the marker, so an attempt's defer can only ever
    /// remove its OWN marker, never a successor's.
    private var sectionsLoadingMore: [String: Int] = [:]

    private var loadedAt: Date?
    private var generation = 0

    /// A-14 (1.3.9): per-plugin snapshots of a completed
    /// load. Switching A→B→A inside the freshness window
    /// restores A's snapshot instead of refetching every
    /// section (the pre-A-14 store cleared items on any
    /// plugin change, so the 600 s freshness only ever
    /// helped a same-plugin revisit).
    private struct PluginSnapshot {
        var sections: [HomeSection]
        var items: [String: [Movie]]
        var sectionErrors: [String: String]
        var heroMovie: Movie?
        var loadedAt: Date
        var pages: [String: Int]
        var totalPages: [String: Int]
        var finished: Set<String>
    }
    private var snapshots: [String: PluginSnapshot] = [:]

    private static let freshnessWindow: TimeInterval = 600

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

    /// Returns whether this call SETTLED as the latest
    /// generation — its outcome (a publish, a snapshot
    /// restore, a freshness no-op, the no-plugin clear) is
    /// the surface's current state. A superseded call
    /// (a newer load started while this one was in flight)
    /// returns false at its generation guards and publishes
    /// nothing. The view's hand-off arm lifetime hangs off
    /// this (gate R2 Lens 1 N1/N2): only a settled load may
    /// close the arm.
    @discardableResult
    func load(plugins: PluginManager, service: MovieService, force: Bool = false) async -> Bool {
        generation &+= 1
        let gen = generation
        guard let pid = plugins.activePlugin?.id else {
            sections = []
            items = [:]
            sectionErrors = [:]
            sectionPages = [:]
            sectionTotalPages = [:]
            sectionFinished = []
            sectionsLoadingMore = [:]
            loadedPluginId = nil
            loadedAt = nil
            heroMovie = nil
            isLoading = false
            // L-T41 §5.3 (1.3.15, gate R1 Lens 3): this
            // exit publishes an empty state too — it gets
            // its own label so a swap into the no-plugin
            // state is visible beside the two named paths.
            DiagLog.log("home", "publish path=clear plugin=none sections=0 items=0 hero=nil")
            return true
        }
        if !force, !isLoading, loadedPluginId == pid, let loadedAt,
           Date().timeIntervalSince(loadedAt) < Self.freshnessWindow {
            isLoading = false
            return true
        }
        // A-14: a fresh snapshot of the TARGET plugin
        // restores instantly — no section refetch.
        if !force, let snapshot = snapshots[pid],
           Date().timeIntervalSince(snapshot.loadedAt) < Self.freshnessWindow {
            sections = snapshot.sections
            items = snapshot.items
            sectionErrors = snapshot.sectionErrors
            sectionPages = snapshot.pages
            sectionTotalPages = snapshot.totalPages
            sectionFinished = snapshot.finished
            heroMovie = snapshot.heroMovie
            loadedPluginId = pid
            loadedAt = snapshot.loadedAt
            didLoad = true
            isLoading = false
            // L-T41 §5.3 (1.3.15): the publish line — which
            // swap just landed on Home, in which shape. The
            // focus lines beside it say where focus went.
            DiagLog.log("home", "publish path=snapshot plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil") failed=\(sectionErrors.count)")
            return true
        }
        if loadedPluginId != pid {
            // A-14: stash the outgoing plugin's published
            // state before clearing, so coming back to it
            // inside the window is a restore, not a reload.
            if let outgoing = loadedPluginId, didLoad, let outAt = loadedAt {
                snapshots[outgoing] = PluginSnapshot(
                    sections: sections, items: items,
                    sectionErrors: sectionErrors,
                    heroMovie: heroMovie, loadedAt: outAt,
                    pages: sectionPages, totalPages: sectionTotalPages,
                    finished: sectionFinished)
            }
            heroMovie = nil
            items = [:]
            sectionErrors = [:]
            sectionPages = [:]
            sectionTotalPages = [:]
            sectionFinished = []
            sectionsLoadingMore = [:]
        }
        isLoading = true
        let secs = await service.homeSections(pluginId: pid)
        guard gen == generation else { return false }
        sections = secs
        loadedPluginId = pid
        if secs.isEmpty {
            heroMovie = nil
            didLoad = true
            isLoading = false
            loadedAt = Date()
            snapshots[pid] = PluginSnapshot(
                sections: secs, items: items, sectionErrors: sectionErrors,
                heroMovie: nil, loadedAt: Date(),
                pages: sectionPages, totalPages: sectionTotalPages,
                finished: sectionFinished)
            // L-T41 §5.3 (1.3.15): publish line, fresh path
            // (the empty-sections landing) — computed from
            // the published state, like the other two.
            DiagLog.log("home", "publish path=fresh plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil") failed=\(sectionErrors.count)")
            return true
        }
        // Per-section page-1 fetches in parallel; each row
        // publishes as its own fetch lands (the iOS shape).
        await withTaskGroup(of: (String, Result<ListPage, Error>).self) { group in
            for section in secs {
                group.addTask {
                    do {
                        let page = try await service.list(pluginId: pid, slug: section.slug,
                                                          filters: ListFilters(), page: 1)
                        return (section.id, .success(page))
                    } catch {
                        return (section.id, .failure(error))
                    }
                }
            }
            for await (sectionId, result) in group {
                guard gen == self.generation else { continue }
                switch result {
                case .success(let page):
                    let movies = page.items
                    items[sectionId] = movies.uniquedById()
                    // L-T42 (1.3.16) + FL-489: page 1 was
                    // REQUESTED, so the counter is 1 — never
                    // the parser-reported currentPage;
                    // totalPages is adopted from the parser.
                    sectionPages[sectionId] = 1
                    sectionTotalPages[sectionId] = max(page.pagination.totalPages, 1)
                    if movies.isEmpty {
                        sectionFinished.insert(sectionId)
                    } else {
                        sectionFinished.remove(sectionId)
                    }
                    sectionErrors[sectionId] = nil
                    if !movies.isEmpty {
                        // FL-488: a section's movies were all
                        // served by the one list page — its URL
                        // rides the prefetch as their Referer.
                        ImageCacheManager.shared.prefetch(urlStrings: movies.map(\.posterUrl),
                                                          headers: movies.first?.sourcePageURL.map { ["Referer": $0] } ?? [:])
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
        if gen == generation {
            // Hero computed ONCE from the final sections/items.
            var hero: Movie?
            for section in sections {
                if let movie = items[section.id]?.first(where: { !$0.displayBackdrop.isEmpty }) {
                    hero = movie
                    break
                }
            }
            heroMovie = hero
            didLoad = true
            isLoading = false
            loadedAt = Date()
            snapshots[pid] = PluginSnapshot(
                sections: sections, items: items, sectionErrors: sectionErrors,
                heroMovie: hero, loadedAt: Date(),
                pages: sectionPages, totalPages: sectionTotalPages,
                finished: sectionFinished)
            // L-T41 §5.3 (1.3.15): publish line, fresh path.
            DiagLog.log("home", "publish path=fresh plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil") failed=\(sectionErrors.count)")
            return true
        }
        return false
    }

    /// L-T42 (1.3.16): append the next page to ONE home
    /// rail, in place at the tail of items[sectionId] —
    /// sections order, heroMovie and focus state are never
    /// touched. FL-489 ownership, same as Browse: the local
    /// counter becomes the REQUESTED page, totalPages is
    /// adopted (never shrunk), and a page adding zero new
    /// items after dedupe finishes the section.
    /// Revalidation: the cursor and item count captured at
    /// entry must still match after the fetch — a
    /// same-generation page-1 republish in between drops
    /// the append instead of stitching a stale page onto
    /// fresh page 1.
    func loadMoreSection(sectionId: String, plugins: PluginManager, service: MovieService) async {
        guard let pid = loadedPluginId, pid == plugins.activePlugin?.id else { return }
        guard let section = sections.first(where: { $0.id == sectionId }) else { return }
        guard let current = sectionPages[sectionId],
              let total = sectionTotalPages[sectionId] else { return }
        guard current < total else { return }
        guard !sectionFinished.contains(sectionId) else { return }
        guard sectionErrors[sectionId] == nil else { return }
        guard sectionsLoadingMore[sectionId] == nil else { return }
        let gen = generation
        sectionsLoadingMore[sectionId] = gen
        defer {
            if sectionsLoadingMore[sectionId] == gen {
                sectionsLoadingMore.removeValue(forKey: sectionId)
            }
        }
        let countAtStart = items[sectionId]?.count ?? 0
        let next = current + 1
        do {
            let result = try await service.list(pluginId: pid, slug: section.slug,
                                                filters: ListFilters(), page: next)
            guard gen == generation, loadedPluginId == pid else { return }
            guard sectionPages[sectionId] == current,
                  (items[sectionId]?.count ?? 0) == countAtStart else { return }
            let existing = items[sectionId] ?? []
            var seen = Set(existing.map(\.id))
            let fresh = result.items.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty {
                items[sectionId] = existing + fresh
                ImageCacheManager.shared.prefetch(urlStrings: fresh.map(\.posterUrl),
                                                  headers: fresh.first?.sourcePageURL.map { ["Referer": $0] } ?? [:])
            }
            sectionPages[sectionId] = next
            sectionTotalPages[sectionId] = max(sectionTotalPages[sectionId] ?? total, result.pagination.totalPages)
            if fresh.isEmpty {
                sectionFinished.insert(sectionId)
            }
            DiagLog.log("home", "rail append section=\(section.slug) page=\(next) added=\(fresh.count) total=\(items[sectionId]?.count ?? 0)")
        } catch {
            DiagLog.log("home", "rail append failed section=\(section.slug) page=\(next) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
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
    /// L-T41 (1.3.15): the content region's OWN landing
    /// focus, inside the swapped region at last — the hero
    /// carries it through its A-6/A-7 entryFocus, the way
    /// Browse's first card carries that screen's. While no
    /// hero exists (loading / empty / error), the landing
    /// falls back to the active chip, which carries the
    /// fallback binding through its own entryFocus so
    /// `.defaultFocus` has a real view to land on.
    @FocusState private var heroFocused: Bool
    @FocusState private var chipFocused: Bool
    /// L-T41 (1.3.15, gate R1 Lens 1): where focus
    /// physically sits, as the hooks report it — true while
    /// any chip on the rail holds focus, false once a
    /// content element (hero / header / card) gains it.
    /// Read from OBSERVED focus (the hooks), never from
    /// chipFocused: the binding migrates between chips as
    /// the active plugin changes (a rebind produces no
    /// focus event and is not guaranteed to rewrite the
    /// newly attached binding), while the hooks fire on
    /// real focus gains — including the gain of the chip
    /// the user just selected, whose focus at that moment
    /// still lives in its own internal state. In 1.3.15
    /// this was the hand-off's guard; since vòng 2 it is
    /// diagnostic state (the arm lines log it) and the
    /// watchdog's rail memory — the obligation's decisions
    /// read the tracker, which names the exact element.
    @State private var focusOnRail = false
    /// L-T41 vòng 2 (1.3.16, DIAGNOSIS-2 §7.2): the landing
    /// is an OBLIGATION, not the 1.3.15 one-shot arm. The
    /// diagnosis convicted the old shape: a single
    /// unconfirmed `heroFocused = true` write whose arm was
    /// closed unconditionally by settleHeroHandOff() in the
    /// same turn the load returned — before the new hero
    /// view existed — and the tree had no resetFocus and no
    /// watchdog, so a missed shot stranded focus (tab bar /
    /// nowhere) until Menu. Now: an obligation opens on a
    /// designed landing (first appear, a user switch, any
    /// settled load, the watchdog) and is discharged ONLY
    /// by a confirmed focus gain — of the target itself
    /// (discharged-by-gain) or of any other live Home
    /// element (closed-by-user-takeover: focus is provably
    /// alive in this scope, the landing is no longer ours
    /// to deliver). While it is open, a bounded chain
    /// re-issues the landing write at +0/+150/+500/+1200 ms
    /// (the measured cold-landing tail is 1.1–1.4 s); a
    /// settle can open or refresh the obligation but can
    /// NEVER close it. `landingGeneration` tokenises the
    /// chain: opening or closing bumps it, so a stale chain
    /// can never fire for a dead obligation.
    @State private var landingOwed = false
    @State private var landingPreferChip = false
    @State private var landingGeneration = 0
    /// The first appear of this view instance opens the
    /// launch landing; later appears (pop-backs, tab
    /// returns) deliberately do NOT — the engine's own
    /// restore owns those, and the watchdog below is the
    /// net if the restore fails (DIAGNOSIS-2 §7.2.5).
    @State private var didOpenInitialLanding = false
    /// Watchdog state (DIAGNOSIS-2 §7.2.3): whether Home
    /// is the appeared surface, its polling task, and the
    /// last confirmed gain (element + time + whether it
    /// sat on the chip rail) — the W2 chip-edge rule and
    /// the watchdog's target selection both read the last
    /// gain.
    @State private var homeAppeared = false
    @State private var watchdogTask: Task<Void, Never>?
    @State private var lastGainElement = "none"
    @State private var lastGainAt: Date?
    @State private var lastGainWasChip = false
    /// L-T41 §5.3 (1.3.15): the focus diagnostics owner —
    /// the move-fail observer and the last focus owner the
    /// hooks reported.
    @State private var focusTracker = TVHomeFocusTracker()

    var body: some View {
        VStack(spacing: 0) {
            if plugins.visiblePlugins.isEmpty {
                // L-T41 (1.3.15, gate R1 Lens 1): with no
                // visible plugins the chip rail and content
                // leave the tree, taking the only other
                // landing declarations with them — this
                // state's button carries the surface's
                // declared landing itself.
                TVEmptyState(icon: "puzzlepiece.extension",
                             title: "Chưa có nguồn plugin",
                             actionTitle: "Đồng bộ ngay",
                             action: { Task { await plugins.syncAll() } },
                             actionIsDefaultFocus: true,
                             onFocusChange: focusHook("empty action=sync"))
            } else {
                chipRail
                content
            }
        }
        .tvThemedBackground()
        .focusScope(focusNS)
        .onAppear {
            session.touch()
            focusTracker.install()
            // L-T41 vòng 2 (1.3.16, DIAGNOSIS-2 §7.1):
            // appear/disappear are logged so navigation
            // windows can never again masquerade as focus
            // windows in the log (the round-1 misread).
            homeAppeared = true
            DiagLog.log("home", "appear")
            if !didOpenInitialLanding {
                didOpenInitialLanding = true
                openLandingObligation(preferChip: false, reason: "appear")
            }
            startFocusWatchdog()
            logLanding()
        }
        .onDisappear {
            homeAppeared = false
            DiagLog.log("home", "disappear")
            watchdogTask?.cancel()
            watchdogTask = nil
            focusTracker.uninstall()
        }
        .task {
            if plugins.installed.isEmpty {
                await plugins.syncAll()
            } else {
                Task { await plugins.syncAll(silent: true) }
            }
            if await store.load(plugins: plugins, service: service) {
                beginLandingObligation()
            }
        }
        .onChange(of: plugins.activePluginId) { _, _ in
            // L-T41 vòng 2 (1.3.16): a user switch opens a
            // landing obligation immediately (focus sits on
            // the tapped chip — the designed parking spot —
            // while the new source loads), and the settle
            // below REFRESHES it when the load lands: the
            // hero-id trigger alone misses a switch whose
            // new hero carries the same movie id as the old
            // one. The settle runs only if this load
            // actually settled as the latest generation; a
            // superseded load leaves the obligation for the
            // winning load. A settle never CLOSES the
            // obligation (DIAGNOSIS-2 §7.2.1) — only a
            // confirmed gain does.
            openLandingObligation(preferChip: false, reason: "switch")
            Task {
                if await store.load(plugins: plugins, service: service) {
                    beginLandingObligation()
                }
            }
            logLanding()
        }
        .onChange(of: store.heroMovie?.id) { _, _ in
            logLanding()
        }
        .onChange(of: plugins.syncGeneration) { _, _ in
            // A sync settle refreshes the obligation like
            // any other settle (it is the freshest load,
            // including when it won a switch race) — but
            // refreshing only RE-ISSUES the landing write;
            // the shot itself obeys the no-steal rule in
            // fireLandingShot(), so a silent sync publish
            // can never yank focus off a live content
            // element the user is browsing (gate R1 Lens 1
            // F5's concern, kept under the new shape).
            Task {
                if await store.load(plugins: plugins, service: service) {
                    beginLandingObligation()
                }
            }
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
                           selected: plugin.id == plugins.activePluginId,
                           // L-T41 (1.3.15): the ACTIVE chip
                           // also carries the shared fallback
                           // binding, so the content region's
                           // .defaultFocus has a real view to
                           // land on while no hero exists. Its
                           // prefersDefaultFocus claim below is
                           // unchanged — it remains the landing
                           // whenever the content has no hero.
                           entryFocus: plugin.id == plugins.activePluginId ? $chipFocused : nil,
                           onFocusChange: focusHook("chip plugin=\(plugin.id)", rail: true)) {
                        plugins.activePluginId = plugin.id
                    }
                    .prefersDefaultFocus(plugin.id == plugins.activePluginId, in: focusNS)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 18)
        }
        .focusSection()
    }

    private var content: some View {
        ScrollView {
            // L-T41 §5.2 (1.3.15): a plain VStack, not a
            // LazyVStack — the band count is small (one hero
            // + at most ~14 bands) and the real laziness
            // lives INSIDE the rails (LazyHStack) and grids
            // (LazyVGrid), which are untouched. A lazy stack
            // only realizes a band when it is about to render,
            // and on tvOS scrolling is a side effect of focus
            // movement: an unrealized band is a focus target
            // that does not exist yet, so the move down fails,
            // nothing scrolls, and the band never realizes —
            // the self-sustaining freeze of L-T41. Realizing
            // every band at publish removes the trap.
            VStack(alignment: .leading, spacing: 44) {
                if let hero = store.heroMovie, let pid = plugins.activePlugin?.id {
                    // L-T41 §5.1 (1.3.15): the hero is no
                    // longer a single-leaf focus section of
                    // its own — the content ScrollView's
                    // section (below) frames the whole scroll
                    // region, and the hero's landing is the
                    // declared defaultFocus + hand-off pair.
                    heroBand(hero: hero, pluginId: pid)
                }
                if !history.continueWatching.isEmpty {
                    continueWatchingBand
                        .focusSection()
                }
                // A-10 (1.3.9) + design pass D-5: the poster
                // bands' long-press favourite toggle gets its
                // ONE hint line here — every rail card and
                // every grid cell below toggles favourite on
                // long press, and the line is stated once for
                // the whole screen, not repeated per band.
                if plugins.activePlugin != nil,
                   store.sections.contains(where: { !(store.items[$0.id] ?? []).isEmpty }) {
                    Text("Giữ lâu một thẻ để ghim / bỏ ghim yêu thích")
                        .font(.system(size: 23))
                        .foregroundStyle(theme.textDim)
                }
                ForEach(store.sections) { section in
                    if let error = store.sectionErrors[section.id], (store.items[section.id] ?? []).isEmpty {
                        // L-T41 (1.3.15, gate R1 Lens 1):
                        // the all-error band holds ONE
                        // focusable (the retry button) — no
                        // section wrapper of its own; the
                        // content ScrollView's section frames
                        // it, like every other band.
                        sectionBand(section)
                    } else if !(store.items[section.id] ?? []).isEmpty {
                        sectionBand(section)
                            .focusSection()
                    }
                }
                if store.didLoad && store.sections.isEmpty && !store.isLoading {
                    // One focusable (the reload button) —
                    // no section wrapper, same rule as the
                    // all-error band above.
                    TVEmptyState(icon: "film.stack", title: "Chưa có nội dung",
                                 actionTitle: "Tải lại",
                                 action: { Task { if await store.load(plugins: plugins, service: service, force: true) { beginLandingObligation() } } },
                                 onFocusChange: focusHook("empty action=reload"))
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
        // L-T41 §5.2 (1.3.15): the scroll region itself is a
        // focus section, so the engine has a section frame
        // spanning the whole content for the step from the
        // pinned chip rail into and through the bands,
        // instead of depending on each band's own section
        // and realization state.
        .focusSection()
        // L-T41 §5.1 (1.3.15): the content region's declared
        // landing, the Browse A-6 shape — the hero whenever
        // one exists, the active chip while it does not
        // (loading / empty / error states included, so the
        // landing exists for EVERY Home state).
        .defaultFocus(store.heroMovie != nil ? $heroFocused : $chipFocused, true)
        // L-T41 §5.1 (1.3.15) → vòng 2 (1.3.16): the
        // hand-off, Browse's A-6 gate fix in shape — a
        // defaultFocus declaration does not move focus that
        // was ALREADY assigned, so when a hero lands (fresh
        // publish or snapshot restore) while focus still
        // sits on the chip rail, hand it to the hero
        // explicitly. The 1.3.15 shape fired that hand-off
        // ONCE and let the settle close the arm; vòng 2
        // makes it one shot of the landing obligation's
        // bounded chain (see openLandingObligation): this
        // trigger is an extra shot opportunity while an
        // obligation is owed, and fireLandingShot() applies
        // the same no-steal rule as every shot, so a silent
        // sync reload can never steal focus to a new hero.
        // The post-load refresh in the activePluginId
        // handler covers the same-hero-id switch this
        // trigger cannot see.
        .onChange(of: store.heroMovie?.id) { _, _ in
            if landingOwed {
                fireLandingShot()
            }
        }
    }

    // MARK: - Focus diagnostics (L-T41 §5.3)

    /// One hook body for every focusable Home element:
    /// a gain/lost line per transition (user-gesture pace,
    /// never per-frame) plus the tracker's current-owner
    /// note that the moveFail and landing lines read. Only
    /// element kinds and ids are logged — the same
    /// secrets-free discipline as every other DiagLog line.
    /// A gain also records whether focus sits on the chip
    /// rail (`rail`) — the hand-off's guard state — and,
    /// since vòng 2, settles the landing obligation: a
    /// confirmed gain is the ONLY thing that can discharge
    /// it (see openLandingObligation).
    private func focusHook(_ element: String, rail: Bool = false) -> (Bool) -> Void {
        { focused in
            if focused {
                focusOnRail = rail
                focusTracker.note(element)
                lastGainElement = element
                lastGainAt = Date()
                lastGainWasChip = rail
                DiagLog.log("focus", "home gain element=\(element)")
                noteLandingGain(element)
            } else {
                focusTracker.clear(if: element)
                DiagLog.log("focus", "home lost element=\(element)")
                noteLandingLoss(element)
            }
        }
    }

    // MARK: - Landing obligation (L-T41 vòng 2, DIAGNOSIS-2 §7.2)

    /// The obligation's target, resolved LIVE at every
    /// use: the hero whenever one is published, the active
    /// chip otherwise — unless the obligation was opened
    /// with a chip preference (the watchdog after a chip
    /// loss, §7.2.3/§7.2.4: focus returns to where it was
    /// last confirmed, not to a hero the user may have
    /// been climbing away from).
    private enum LandingTarget: String {
        case hero
        case chip
    }

    private var landingTarget: LandingTarget {
        (landingPreferChip || store.heroMovie == nil) ? .chip : .hero
    }

    /// Does this hook element descriptor name the element
    /// the obligation currently targets? The hero matches
    /// by kind (its movie id changes per publish); the chip
    /// target matches ONLY the active plugin's chip — a
    /// gain on a neighbouring chip is the user walking the
    /// rail, not the landing arriving.
    private func elementMatchesLandingTarget(_ element: String) -> Bool {
        switch landingTarget {
        case .hero:
            return element.hasPrefix("hero")
        case .chip:
            return element == "chip plugin=\(plugins.activePluginId)"
        }
    }

    /// Open (or refresh) the landing obligation and start
    /// its bounded re-fire chain. Called by every designed
    /// landing: first appear, a user switch, every settled
    /// load (via beginLandingObligation), the watchdog and
    /// the W2 chip-edge rule (the latter two with their own
    /// event names). Refreshing restarts the schedule from
    /// +0 — the settle is the moment the target view
    /// actually exists, so the chain that matters starts
    /// there.
    private func openLandingObligation(preferChip: Bool, reason: String) {
        landingOwed = true
        landingPreferChip = preferChip
        landingGeneration &+= 1
        let event = reason == "watchdog" ? "watchdog-reopen" : "open"
        DiagLog.log("focus", "arm event=\(event) target=\(landingTarget.rawValue) reason=\(reason) focusOnRail=\(focusOnRail) tracker=\(focusTracker.current)")
        runLandingChain(generation: landingGeneration)
    }

    /// A load that settled as the latest generation
    /// (re)opens the obligation — the same-hero-id rescue
    /// (the settled load may have republished the hero the
    /// hero-id trigger cannot see) and the publish-moment
    /// refresh in one. It NEVER closes the obligation:
    /// that was the 1.3.15 defect (DIAGNOSIS-2 §1). A
    /// SUPERSEDED load never reaches here — its caller saw
    /// `false` and skipped the settle, leaving the
    /// obligation for the winning load (N1).
    private func beginLandingObligation() {
        openLandingObligation(preferChip: false, reason: "settle")
    }

    /// The bounded re-fire chain (DIAGNOSIS-2 §7.2.2):
    /// shots at +0/+150/+500/+1200 ms from the open,
    /// covering the measured 1.1–1.4 s cold-landing tail.
    /// The chain is tokenised by generation — an open or a
    /// close bumps the generation and every stale chain
    /// dies at its next checkpoint. If the schedule runs
    /// out with the obligation still owed and focus still
    /// not observably on the target, the obligation closes
    /// as EXHAUSTED (logged, never silent): the watchdog
    /// remains the net for a void that outlives the chain.
    private func runLandingChain(generation gen: Int) {
        Task { @MainActor in
            let offsets: [Int] = [0, 150, 500, 1200]
            var elapsed = 0
            for (index, offset) in offsets.enumerated() {
                if offset > elapsed {
                    try? await Task.sleep(for: .milliseconds(offset - elapsed))
                    elapsed = offset
                }
                guard landingOwed, landingGeneration == gen else { return }
                if index > 0 {
                    DiagLog.log("focus", "arm event=refire n=\(index) target=\(landingTarget.rawValue) tracker=\(focusTracker.current)")
                }
                fireLandingShot()
            }
            // A short grace past the last shot: the gain it
            // produces lands on the next render pass, and a
            // landing that arrives inside the grace is a
            // delivery, not an exhaustion.
            try? await Task.sleep(for: .milliseconds(300))
            guard landingOwed, landingGeneration == gen else { return }
            if elementMatchesLandingTarget(focusTracker.current) {
                closeLandingObligation(event: "discharged-by-gain", detail: "observed")
            } else {
                closeLandingObligation(event: "exhausted", detail: "schedule-spent")
            }
        }
    }

    /// One landing shot: write the target's FocusState
    /// binding — unless focus is already observably alive
    /// somewhere the shot must not disturb:
    /// - already ON the target → the landing has in fact
    ///   arrived; discharge it as a gain (the hook normally
    ///   beats the chain to this, the check covers a gain
    ///   the hooks somehow missed);
    /// - on a live CONTENT element that is not the target →
    ///   the user is browsing inside Home; close as
    ///   user-takeover WITHOUT firing (the no-steal rule —
    ///   a settle or a sync publish must never yank focus
    ///   off a card the user is standing on);
    /// - on the chip rail, or nowhere the hooks can see →
    ///   fire: rail→hero is the designed hand-off, and
    ///   nowhere is exactly the void this chain exists to
    ///   close.
    private func fireLandingShot() {
        guard landingOwed else { return }
        let current = focusTracker.current
        if elementMatchesLandingTarget(current) {
            closeLandingObligation(event: "discharged-by-gain", detail: "observed")
            return
        }
        if current != "none", !current.hasPrefix("chip") {
            closeLandingObligation(event: "closed-by-user-takeover", detail: "observed=\(current)")
            return
        }
        switch landingTarget {
        case .hero: heroFocused = true
        case .chip: chipFocused = true
        }
    }

    /// Every close of the obligation funnels through here:
    /// the state clears, the generation bumps (killing any
    /// live chain), and the mutation is logged — the arm's
    /// whole life is visible in the log (DIAGNOSIS-2 §7.1).
    private func closeLandingObligation(event: String, detail: String) {
        guard landingOwed else { return }
        landingOwed = false
        landingGeneration &+= 1
        DiagLog.log("focus", "arm event=\(event) target=\(landingTarget.rawValue) \(detail) tracker=\(focusTracker.current)")
    }

    /// A confirmed gain settles the obligation (the hook
    /// calls this for every gain): the target's own gain
    /// discharges it as delivered; any OTHER live Home
    /// element's gain closes it as user-takeover — focus
    /// is provably alive in this scope, so the landing is
    /// no longer owed. ONE exception, the designed
    /// intermediate: a gain of the ACTIVE chip while the
    /// target is the hero does NOT close anything — the
    /// engine parks focus on the chip first on every cold
    /// start in the evidence log (3/3 launches gained a
    /// chip before the hero), and that parking spot is
    /// exactly what the re-fire chain exists to convert;
    /// closing there would rebuild the one-shot dependency
    /// the diagnosis convicted.
    private func noteLandingGain(_ element: String) {
        guard landingOwed else { return }
        if elementMatchesLandingTarget(element) {
            closeLandingObligation(event: "discharged-by-gain", detail: "element=\(element)")
            return
        }
        if landingTarget == .hero,
           element == "chip plugin=\(plugins.activePluginId)" {
            return
        }
        closeLandingObligation(event: "closed-by-user-takeover", detail: "element=\(element)")
    }

    /// The W2 chip-edge guard (DIAGNOSIS-2 §2.3): a chip
    /// gain followed within ~0.3 s by focus reading NONE —
    /// the climb off the top of the chip rail, where the
    /// engine refused the press and the app contributed
    /// nothing to the recovery (×3 in the evidence log) —
    /// re-lands on the active chip immediately: an
    /// obligation with a chip preference, whose +0 shot
    /// fires in the same turn. A loss that is really a move
    /// (chip → hero, chip → chip) is followed at once by
    /// the destination's gain, which closes this
    /// obligation as user-takeover before its first shot
    /// can land.
    private func noteLandingLoss(_ element: String) {
        guard element.hasPrefix("chip"),
              element == lastGainElement,
              let gainedAt = lastGainAt,
              Date().timeIntervalSince(gainedAt) <= 0.3,
              focusTracker.current == "none",
              homeAppeared, nav.path.isEmpty
        else { return }
        openLandingObligation(preferChip: true, reason: "chip-edge")
    }

    /// The focus-presence watchdog (DIAGNOSIS-2 §7.2.3):
    /// while Home is the appeared root surface (no pushed
    /// view covering it), a tracker reading of NONE that
    /// persists past ~1.5 s re-opens the landing
    /// obligation ONCE per void episode — target = the
    /// chip if the last confirmed gain sat on the rail
    /// (the W2 shape), else the standing hero/chip rule.
    /// The episode re-arms only when focus is seen alive
    /// again, so a permanent void costs one reland, not a
    /// log flood; and the worst case for any void becomes
    /// ~1.5 s + the chain, never an infinite freeze.
    private func startFocusWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor in
            var voidSince: Date?
            var relandedThisEpisode = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                guard homeAppeared, nav.path.isEmpty else {
                    voidSince = nil
                    relandedThisEpisode = false
                    continue
                }
                if focusTracker.current == "none" {
                    if voidSince == nil { voidSince = Date() }
                    if let since = voidSince,
                       Date().timeIntervalSince(since) > 1.5,
                       !relandedThisEpisode, !landingOwed {
                        relandedThisEpisode = true
                        DiagLog.log("focus", "watchdog reland after=\(String(format: "%.1f", Date().timeIntervalSince(since)))s lastGain=\(lastGainElement)")
                        openLandingObligation(preferChip: lastGainWasChip, reason: "watchdog")
                    }
                } else {
                    voidSince = nil
                    relandedThisEpisode = false
                }
            }
        }
    }

    /// The landing audit lines: which element SHOULD hold
    /// focus after an (re)entry or a content swap vs the
    /// owner the hooks actually reported. Samples at
    /// +300 ms AND +1200 ms (DIAGNOSIS-2 §7.1): the +300 ms
    /// sample alone misread cold landings (1.1–1.4 s) as
    /// failures all through the evidence log — the late
    /// sample separates landed-slow from landed-never.
    /// Both sides are read at sample time (gate R1 Lens 3:
    /// a target captured at trigger time can be stale for
    /// the swap it audits).
    private func logLanding() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            let target = store.heroMovie != nil ? "hero" : "chip"
            DiagLog.log("focus", "landing scope=home target=\(target) actual=\(focusTracker.current) late=300ms")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            let target = store.heroMovie != nil ? "hero" : "chip"
            DiagLog.log("focus", "landing scope=home target=\(target) actual=\(focusTracker.current) late=1200ms")
        }
    }

    private func heroBand(hero: Movie, pluginId: String) -> some View {
        TVHeroCard(movie: hero,
                   onSelect: {
                       nav.push(.movie(MovieRoute(pluginId: pluginId, movie: hero, autoResume: false)))
                   },
                   onFocusChange: focusHook("hero movie=\(hero.id)"),
                   entryFocus: $heroFocused)
    }

    /// One rail card (L-T42's append trigger rides its
    /// focus hook, unchanged): gaining focus within the
    /// last four cards of the rail asks the store for the
    /// next page. Factored out of sectionBand in vòng 2 so
    /// the eager head and the lazy tail build the identical
    /// card — `globalIndex` is the card's index in the
    /// section's full item list either way.
    private func railCard(movie: Movie, pluginId pid: String, section: HomeSection,
                          globalIndex index: Int, totalCount: Int) -> some View {
        TVPosterCard(movie: movie, width: 240,
                     isFavorite: favorites.isFavorite(pluginId: pid, movieId: movie.id),
                     onSelect: {
                         nav.push(.movie(MovieRoute(pluginId: pid, movie: movie)))
                     },
                     onLongPress: {
                         favorites.toggle(pluginId: pid, movie: movie)
                     },
                     onFocusChange: { focused in
                         focusHook("card movie=\(movie.id)")(focused)
                         if focused == true, index >= totalCount - 4 {
                             Task { await store.loadMoreSection(sectionId: section.id, plugins: plugins, service: service) }
                         }
                     })
    }

    private var continueWatchingBand: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: "Đang xem tiếp")
            // A-10 (1.3.9): the long-press gesture gets a
            // discoverable hint line.
            Text("Giữ lâu một thẻ để xoá khỏi Đang xem tiếp")
                .font(.system(size: 23))
                .foregroundStyle(theme.textDim)
            // L-T41 vòng 2 (1.3.16, DIAGNOSIS-2 §7.2.5):
            // the same non-lazy head as the section rails —
            // the first screenful of Continue Watching cards
            // is realized eagerly, the rest stays lazy.
            let records = history.continueWatching
            let head = Array(records.prefix(6))
            let tail = Array(records.dropFirst(6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(head) { record in
                        continueCard(record)
                    }
                    if !tail.isEmpty {
                        LazyHStack(spacing: 24) {
                            ForEach(tail) { record in
                                continueCard(record)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func continueCard(_ record: HistoryRecord) -> some View {
        TVLandscapeCard(record: record, width: 400,
                        onSelect: {
                            nav.push(.movie(MovieRoute(pluginId: record.pluginId,
                                                       movie: record.movie,
                                                       autoResume: true)))
                        },
                        onLongPress: {
                            history.remove(record)
                        },
                        onFocusChange: focusHook("card movie=\(record.movie.id)"))
    }

    @ViewBuilder
    private func sectionBand(_ section: HomeSection) -> some View {
        let movies = store.items[section.id] ?? []
        if let error = store.sectionErrors[section.id], movies.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TVSectionHeader(title: section.title)
                TVSectionErrorRow(message: error,
                                  onRetry: {
                                      Task {
                                          if await store.load(plugins: plugins, service: service, force: true) {
                                              beginLandingObligation()
                                          }
                                      }
                                  },
                                  onFocusChange: focusHook("retry section=\(section.slug)"))
            }
        } else if !movies.isEmpty, let pid = plugins.activePlugin?.id {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader(title: section.title,
                                action: {
                                    nav.push(.category(CategoryRoute(pluginId: pid, slug: section.slug,
                                                                     title: section.title, filters: ListFilters())))
                                },
                                onFocusChange: focusHook("header section=\(section.slug)"))
                if section.isGrid {
                    TVPosterGrid(items: Array(movies.prefix(9)), pluginId: pid,
                                 isLoadingMore: false, onSelect: nil,
                                 onLoadMore: {},
                                 onCellFocusChange: { movie, focused in
                                     focusHook("card movie=\(movie.id)")(focused)
                                 })
                } else {
                    // L-T41 vòng 2 (1.3.16, DIAGNOSIS-2 §7.2.5):
                    // the rail's HEAD segment is NOT lazy — the
                    // first screenful of cards is realized
                    // eagerly in a plain HStack, the remainder
                    // keeps the LazyHStack. W1 in the evidence
                    // log: after a pop back from Category, four
                    // presses died from the section header in
                    // 1.7 s and the fifth went through, with no
                    // state change in between — the lazy rail
                    // had not re-realized its first card yet,
                    // so the DOWN target did not exist as a
                    // view when the engine searched. An eager
                    // head makes the DOWN target exist from the
                    // first frame after the pop.
                    let head = Array(movies.prefix(6))
                    let tail = Array(movies.dropFirst(6))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 24) {
                            ForEach(Array(head.enumerated()), id: \.element.id) { index, movie in
                                railCard(movie: movie, pluginId: pid, section: section,
                                         globalIndex: index, totalCount: movies.count)
                            }
                            if !tail.isEmpty {
                                LazyHStack(spacing: 24) {
                                    ForEach(Array(tail.enumerated()), id: \.element.id) { index, movie in
                                        railCard(movie: movie, pluginId: pid, section: section,
                                                 globalIndex: head.count + index, totalCount: movies.count)
                                    }
                                }
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
    /// L-T41 (1.3.15, gate R1 Lens 3): an optional
    /// focus-change hook, the poster card's contract —
    /// Home's focus diagnostics need to know when the
    /// retry button takes or leaves focus. Default nil:
    /// the row behaves exactly as before.
    var onFocusChange: ((Bool) -> Void)? = nil

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
            .onChange(of: retryFocused) { _, focused in onFocusChange?(focused) }
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
    /// L-T41 (1.3.15): the A-6/A-7 opt-ins, the poster
    /// card's exact contract — Home's landing hand-off
    /// drives the hero through `entryFocus`, and its focus
    /// diagnostics read `onFocusChange`. Before 1.3.15 the
    /// hero was mute: a private @FocusState nobody outside
    /// could drive or observe, so after every content swap
    /// the engine's fallback decided where focus went.
    /// Both default to the pre-1.3.15 behaviour (own
    /// binding, no hook).
    var onFocusChange: ((Bool) -> Void)? = nil
    var entryFocus: FocusState<Bool>.Binding? = nil

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool
    @State private var imageFailed = false
    @State private var retryToken = 0
    /// A-3 (1.3.9): the current failure has had its one
    /// retry tap; the next tap selects (the poster card's
    /// two-tap rule, hero form).
    @State private var retriedSinceFailure = false

    private let radius: CGFloat = 22

    private var focusActive: Bool {
        entryFocus?.wrappedValue ?? isFocused
    }

    var body: some View {
        Button {
            if imageFailed && !retriedSinceFailure {
                retriedSinceFailure = true
                retryToken += 1
            } else {
                onSelect()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.cardFill)
                TVRemoteImage(urlString: movie.displayBackdrop,
                              headers: movie.sourcePageURL.map { ["Referer": $0] } ?? [:],
                              bucket: 1920,
                              failed: $imageFailed, retryToken: retryToken)
                if imageFailed {
                    theme.backgroundGradient
                }
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
                    .fill(Color.white.opacity(focusActive ? 0.08 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focusActive ? theme.focusRing : .clear,
                                  lineWidth: focusActive ? theme.ringWidth : 0)
            }
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused(entryFocus ?? $isFocused)
        .onChange(of: movie.id) { imageFailed = false; retryToken = 0; retriedSinceFailure = false }
        .onChange(of: imageFailed) { _, failed in
            if !failed { retriedSinceFailure = false }
        }
        .onChange(of: focusActive) { _, focused in onFocusChange?(focused) }
    }
}

// MARK: - Focus tracker (L-T41 §5.3)

/// Owns Home's passive focus-movement-failure observer
/// and the last focus owner the view's hooks reported.
///
/// The observer is PASSIVE: it only listens for
/// `UIFocusSystem.movementDidFailNotification` — the
/// engine's own broadcast when a remote press finds no
/// candidate in that direction — and writes one DiagLog
/// line pairing the failure with BOTH witnesses: the
/// engine's own `focusedItem` (vòng 2 — tab bar vs a Home
/// view vs genuinely nowhere) and the element the hooks
/// say held focus (`tracker=`). That pairing is the
/// decisive evidence for this fault family; a press that
/// produces neither a gain nor a moveFail line points at
/// the input path instead. The tree forbids
/// `.onMoveCommand` for this (an active handler can itself
/// change focus behaviour); nothing here ever requests a
/// focus update.
///
/// Concurrency shape (the FL-495 discipline): all state
/// is instance state of this one object, and EVERY access
/// to it goes through `lock` — the hooks call in from
/// SwiftUI callbacks, the observer block from the main
/// queue — which is what the `@unchecked Sendable`
/// conformance states. The codebase's own shape for
/// lock-guarded shared state (DiagLog, SourceReputation).
/// No static or global mutable state is introduced.
private final class TVHomeFocusTracker: @unchecked Sendable {
    private let lock = NSLock()
    /// The element descriptor the hooks last reported as
    /// focused ("hero movie=…", "chip plugin=…", …), or
    /// "none" before the first gain / after its loss.
    /// Read and written only under `lock`.
    private var _current = "none"
    private var token: NSObjectProtocol?

    var current: String {
        lock.withLock { _current }
    }

    func note(_ element: String) {
        lock.withLock { _current = element }
    }

    func clear(if element: String) {
        lock.withLock {
            if _current == element { _current = "none" }
        }
    }

    func install() {
        let shouldRegister = lock.withLock {
            guard token == nil else { return false }
            return true
        }
        guard shouldRegister else { return }
        let newToken = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.movementDidFailNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DiagLog.log("focus", "moveFail focusedItem=\(Self.focusedItemDescription()) tracker=\(self.current)")
        }
        lock.withLock { token = newToken }
    }

    /// Where the ENGINE says focus actually is at the
    /// moment of the failed press — read from
    /// `UIFocusSystem.focusedItem`, the UIKit-level witness
    /// the hooks cannot be (DIAGNOSIS-2 §7.1): it
    /// distinguishes the three states the tracker alone
    /// cannot — focus on the TAB BAR (a tab-bar ancestor or
    /// a tab title in the label), focus on a real view
    /// inside Home, or genuinely nowhere (`nil`). The
    /// 1.3.15 line tried to read the press DIRECTION out of
    /// this notification's userInfo instead; that payload
    /// does not exist (13/13 `dir=unknown` in the evidence
    /// log), so the direction extraction is REMOVED, not
    /// replaced — no line in this file guesses a direction
    /// any more. Description only: item class, a tab-bar
    /// marker when the item lives in one, and its
    /// accessibility label (spaces folded, truncated) —
    /// ids/labels only, the standing DiagLog discipline.
    private static func focusedItemDescription() -> String {
        guard let window = activeKeyWindow(),
              let item = UIFocusSystem(for: window)?.focusedItem
        else { return "nil" }
        var desc = String(describing: type(of: item))
        if let view = item as? UIView {
            var ancestor: UIView? = view
            while let a = ancestor {
                if a is UITabBar {
                    desc = "tabbar:" + desc
                    break
                }
                ancestor = a.superview
            }
            if let label = view.accessibilityLabel, !label.isEmpty {
                let folded = label.replacingOccurrences(of: " ", with: "_")
                desc += " label=\(String(folded.prefix(40)))"
            }
        }
        return desc
    }

    private static func activeKeyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive
            else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            return windowScene.windows.first
        }
        return nil
    }

    func uninstall() {
        let old: NSObjectProtocol? = lock.withLock {
            let old = token
            token = nil
            return old
        }
        if let old {
            NotificationCenter.default.removeObserver(old)
        }
    }
}
