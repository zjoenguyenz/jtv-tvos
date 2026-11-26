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
            sectionsLoadingMore = []
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
            DiagLog.log("home", "publish path=snapshot plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil")")
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
            sectionsLoadingMore = []
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
            DiagLog.log("home", "publish path=fresh plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil")")
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
            DiagLog.log("home", "publish path=fresh plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil")")
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
    /// THIS is the hand-off's guard, not chipFocused: the
    /// binding migrates between chips as the active plugin
    /// changes (a rebind produces no focus event and is not
    /// guaranteed to rewrite the newly attached binding),
    /// while the hooks fire on real focus gains — including
    /// the gain of the chip the user just selected, whose
    /// focus at that moment still lives in its own internal
    /// state. Browse's A-6 rule, with the guard read from
    /// observed focus instead of a binding.
    @State private var focusOnRail = false
    /// L-T41 (1.3.15, gate R1 Lens 1): the hand-off is
    /// armed only by a landing the app itself designed —
    /// the launch load (initial value) and user-initiated
    /// plugin switches. A silent sync reload that lands a
    /// new hero while the user browses the rail must not
    /// steal focus to it. One-shot: the hero-id trigger and
    /// the post-load check both disarm after firing.
    @State private var heroSwapArmed = true
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
            logLanding()
        }
        .onDisappear { focusTracker.uninstall() }
        .task {
            if plugins.installed.isEmpty {
                await plugins.syncAll()
            } else {
                Task { await plugins.syncAll(silent: true) }
            }
            if await store.load(plugins: plugins, service: service) {
                settleHeroHandOff()
            }
        }
        .onChange(of: plugins.activePluginId) { _, _ in
            // L-T41 (1.3.15, gate R1 Lens 1): a user switch
            // arms the hero hand-off, and the check runs
            // again when the load SETTLES — the hero-id
            // trigger alone misses a switch whose new hero
            // carries the same movie id as the old one.
            // Gate R2 Lens 1 N1/N2: the settle runs only if
            // this load actually settled as the latest
            // generation; a superseded load leaves the arm
            // for the winning load, and a settled load
            // always closes it (see settleHeroHandOff).
            heroSwapArmed = true
            Task {
                if await store.load(plugins: plugins, service: service) {
                    settleHeroHandOff()
                }
            }
            logLanding()
        }
        .onChange(of: store.heroMovie?.id) { _, _ in
            logLanding()
        }
        .onChange(of: plugins.syncGeneration) { _, _ in
            // A sync load never ARMS the hand-off (gate R1
            // Lens 1 F5); if one settles while an arm is
            // live, it is the freshest load, so it closes
            // the arm like any other settle (gate R2 Lens 1
            // N1/N2) — including delivering the landing when
            // it is the load that won a switch race.
            Task {
                if await store.load(plugins: plugins, service: service) {
                    settleHeroHandOff()
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
                                 action: { Task { if await store.load(plugins: plugins, service: service, force: true) { settleHeroHandOff() } } },
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
        // L-T41 §5.1 (1.3.15): the hand-off, Browse's A-6
        // gate fix in shape — a defaultFocus declaration
        // does not move focus that was ALREADY assigned, so
        // when a hero lands (fresh publish or snapshot
        // restore) while focus still sits on the chip rail,
        // hand it to the hero explicitly. Two gate-R1
        // hardenings over the naive shape: the guard reads
        // OBSERVED focus (focusOnRail, fed by the hooks),
        // not the chip's binding — the binding migrates
        // between chips on every switch and a rebind is not
        // guaranteed to rewrite it; and the trigger only
        // fires while a designed landing is armed (launch
        // or a user switch), so a silent sync reload can
        // never steal focus to a new hero. The post-load
        // check in the activePluginId handler covers the
        // same-hero-id switch this trigger cannot see.
        .onChange(of: store.heroMovie?.id) { _, _ in
            if heroSwapArmed {
                handOffToHeroIfOnRail()
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
    /// rail (`rail`) — the hand-off's guard state.
    private func focusHook(_ element: String, rail: Bool = false) -> (Bool) -> Void {
        { focused in
            if focused {
                focusOnRail = rail
                focusTracker.note(element)
                DiagLog.log("focus", "home gain element=\(element)")
            } else {
                focusTracker.clear(if: element)
                DiagLog.log("focus", "home lost element=\(element)")
            }
        }
    }

    /// The hero hand-off (see the trigger on `content`):
    /// if a designed landing is armed and focus observably
    /// sits on the chip rail, give it to the hero. Firing
    /// disarms, so a later publish in the same swap cannot
    /// move focus twice — but the arm is spent ONLY by a
    /// decision, never by a non-event (gate R2 Lens 1):
    /// focus observed off the rail closes it (the user has
    /// moved on; this landing is not ours to deliver),
    /// while a hero publish that has not landed yet leaves
    /// it armed — a superseding load is still in flight
    /// and its publish will fire the hero-id trigger (N1).
    /// The arm's outer bound is the settle below (N2).
    private func handOffToHeroIfOnRail() {
        guard heroSwapArmed else { return }
        guard focusOnRail else {
            heroSwapArmed = false
            return
        }
        guard store.heroMovie != nil else { return }
        heroSwapArmed = false
        heroFocused = true
    }

    /// A load that settled as the latest generation closes
    /// the hand-off arm: try the hand-off (this is the
    /// same-hero-id rescue — the settled load may have
    /// republished the hero the trigger cannot see), then
    /// disarm regardless. The arm therefore never outlives
    /// the load it was armed for: a launch or switch whose
    /// load settles hero-less lands on the chip by design,
    /// and no later background publish can spend a stale
    /// arm to yank focus (gate R2 Lens 1 N2). A SUPERSEDED
    /// load never reaches here — its caller saw `false`
    /// and skipped the settle, leaving the arm for the
    /// winning load's publish (N1).
    private func settleHeroHandOff() {
        handOffToHeroIfOnRail()
        heroSwapArmed = false
    }

    /// The landing audit line: which element SHOULD hold
    /// focus after an (re)entry or a content swap vs the
    /// owner the hooks actually reported. Both sides are
    /// read at sample time, 300 ms after the trigger, so
    /// the publish and the hand-off have settled (gate R1
    /// Lens 3: a target captured at trigger time can be
    /// stale for the swap it audits). Together with the
    /// gain lines it separates "landed in the wrong place"
    /// from "landed right, cannot move".
    private func logLanding() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            let target = store.heroMovie != nil ? "hero" : "chip"
            DiagLog.log("focus", "landing scope=home target=\(target) actual=\(focusTracker.current)")
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

    private var continueWatchingBand: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: "Đang xem tiếp")
            // A-10 (1.3.9): the long-press gesture gets a
            // discoverable hint line.
            Text("Giữ lâu một thẻ để xoá khỏi Đang xem tiếp")
                .font(.system(size: 23))
                .foregroundStyle(theme.textDim)
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
                                        },
                                        onFocusChange: focusHook("card movie=\(record.movie.id)"))
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
                TVSectionErrorRow(message: error,
                                  onRetry: {
                                      Task {
                                          if await store.load(plugins: plugins, service: service, force: true) {
                                              settleHeroHandOff()
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 24) {
                            ForEach(Array(movies.enumerated()), id: \.element.id) { index, movie in
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
                                                 if focused == true, index >= movies.count - 4 {
                                                     Task { await store.loadMoreSection(sectionId: section.id, plugins: plugins, service: service) }
                                                 }
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
/// line pairing the failure with the element the hooks
/// say held focus. That pairing is the decisive evidence
/// for this fault family: a moveFail line with
/// `focused=hero …` convicts the candidate search; a press
/// that produces neither a gain nor a moveFail line points
/// at the input path instead. The tree forbids
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
        ) { [weak self] notification in
            guard let self else { return }
            DiagLog.log("focus", "moveFail dir=\(Self.direction(of: notification)) focused=\(self.current)")
        }
        lock.withLock { token = newToken }
    }

    /// The failed press's direction, best-effort: the
    /// focus update context rides the notification's
    /// userInfo under the UIFocusUpdateContext key (the
    /// payload WWDC17 documents for the sibling
    /// UIFocusDidUpdate notification) and its
    /// `focusHeading` names the direction. If the payload
    /// is absent or carries no cardinal heading, the line
    /// says `unknown` rather than guessing — the decisive
    /// half of the line is `focused=`, which never depends
    /// on this.
    private static func direction(of notification: Notification) -> String {
        guard let context = notification.userInfo?["UIFocusUpdateContext"] as? UIFocusUpdateContext
        else { return "unknown" }
        let heading = context.focusHeading
        if heading.contains(.up) { return "up" }
        if heading.contains(.down) { return "down" }
        if heading.contains(.left) { return "left" }
        if heading.contains(.right) { return "right" }
        return "unknown"
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
