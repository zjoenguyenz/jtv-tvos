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

    /// L-T42 vòng 3 (1.3.19): the background rail fill — after
    /// a source publishes, every horizontal rail is topped up
    /// from its next pages in the background, so the rails are
    /// already long when the user steps through them (log_8:
    /// every publish was page 1 only — 12 cards a rail — and in
    /// three sessions the owner never reached the focus-driven
    /// append trigger; on iOS the same rails feel endless
    /// because scrolling is continuous). One fill per published
    /// plugin; a new load cancels it (and its generation guard
    /// would drop its results anyway).
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    /// 1.3.20 (F-3): the fill's identity and liveness, so a
    /// freshness no-op can tell whether a fill is still running
    /// and resume one that is not.
    @ObservationIgnored private var fillID = 0
    @ObservationIgnored private var fillActive = false
    /// 1.3.20 (F-4): the background fill is a HEAD START, not a
    /// size. Each horizontal rail is pre-loaded this far ahead
    /// in the background (≈4 pages of a 12-item source) so the
    /// first screens never wait; past it, `ensureLookahead`
    /// keeps `scrollLookahead` cards loaded ahead of the focused
    /// card for as long as the user keeps scrolling, until the
    /// SOURCE's own last page. No app-side cap exists anywhere.
    static let fillLookahead = 48
    static let scrollLookahead = 36
    /// 1.3.20 (F-4): per-rail scroll-lookahead loops, and the
    /// furthest card index the user has focused in each rail.
    @ObservationIgnored private var lookaheadRunning: Set<String> = []
    @ObservationIgnored private var lookaheadFocus: [String: Int] = [:]
    /// 1.3.20 (F-3): the plugin the in-flight load belongs to
    /// (nil when nothing is loading) — a second load request
    /// for the same plugin JOINS it instead of restarting it.
    @ObservationIgnored private var loadingPluginId: String?

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

    /// L-T44 (1.3.17, DESIGN §4.2.2): the ONE gate every
    /// snapshot write passes through (the A-14 stash, the
    /// empty-sections landing, the final publish). A
    /// content-free snapshot — zero total items AND no
    /// section errors — certifies nothing (in the evidence
    /// session it was the in-flight state of a superseded
    /// load, stamped with another plugin's loadedAt) and
    /// is never written. A zero-item snapshot WITH errors
    /// is a dead source's true record and IS written (it
    /// is still never restored — load()'s restore branch
    /// revalidates on items). `at` is the completion time
    /// the snapshot certifies: the outgoing plugin's own
    /// loadedAt at the stash, now at a publish.
    private func storeSnapshot(for pid: String, hero: Movie?, at date: Date) {
        let totalItems = items.values.reduce(0) { $0 + $1.count }
        guard totalItems > 0 || !sectionErrors.isEmpty else { return }
        snapshots[pid] = PluginSnapshot(
            sections: sections, items: items,
            sectionErrors: sectionErrors,
            heroMovie: hero, loadedAt: date,
            pages: sectionPages, totalPages: sectionTotalPages,
            finished: sectionFinished)
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
        guard let pid = plugins.activePlugin?.id else {
            generation &+= 1
            loadingPluginId = nil
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
        // 1.3.20 (F-3): the two no-op exits come BEFORE the
        // generation bump. In 1.3.19 every call bumped the
        // generation first, so a freshness no-op — the plugin
        // sync's settle reload (log_9 11:55:46.837) or a Home
        // re-appear's `.task` (11:58:18.872) — silently killed
        // the running background fill (`rail fill stopped …
        // reason=superseded pages=1`) without loading anything.
        // A no-op now leaves the generation, and therefore the
        // fill, alone; an idle fill is resumed instead.
        if !force, !isLoading, loadedPluginId == pid, let loadedAt,
           Date().timeIntervalSince(loadedAt) < Self.freshnessWindow {
            isLoading = false
            if !fillActive {
                startBackgroundFill(plugins: plugins, service: service, reason: "resume")
            }
            return true
        }
        // 1.3.20 (F-3): a load of THIS plugin already in flight
        // is joined, not restarted. log_9 11:57:44.002: Home's
        // re-appear restarted hentaihub's in-flight load and
        // threw away 8 settled sections (`load superseded
        // plugin=hentaihub settled=8`) — the load the user was
        // looking at. Only a switch to another plugin (or an
        // explicit retry, `force`) supersedes a running load.
        if !force, isLoading, loadingPluginId == pid {
            DiagLog.log("home", "load joined plugin=\(pid) reason=in-flight")
            return false
        }
        generation &+= 1
        let gen = generation
        // A-14: a fresh snapshot of the TARGET plugin
        // restores instantly — no section refetch.
        // L-T44 (1.3.17, DESIGN §4.2.3): restore must
        // revalidate when empty — a snapshot exists to
        // spare a refetch of CONTENT, and a snapshot with
        // zero total items holds no content, so it is
        // never restored: the call falls through to the
        // fresh fetch below, the only road by which a
        // source that died (and has since revived) comes
        // back, and by which a still-dead source publishes
        // its honest per-section errors instead of a
        // blank page. (Snapshots carrying items == 0 WITH
        // section errors are real records of a dead
        // source and may still be WRITTEN — §4.2.2 — they
        // are just never served from here.)
        if !force, let snapshot = snapshots[pid],
           snapshot.items.values.reduce(0) { $0 + $1.count } > 0,
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
            loadingPluginId = nil
            lookaheadFocus = [:]
            DiagLog.log("home", "publish path=snapshot plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil") failed=\(sectionErrors.count)")
            startBackgroundFill(plugins: plugins, service: service, reason: "publish")
            return true
        }
        if loadedPluginId != pid {
            // A-14: stash the outgoing plugin's published
            // state before clearing, so coming back to it
            // inside the window is a restore, not a reload.
            // L-T44 (1.3.17, DESIGN §4.2.1): the stash may
            // only photograph a SETTLED state. The evidence
            // session's corpse was born here: the outgoing
            // plugin's load was still in flight (its section
            // fetches dying against a dead relay) while the
            // store-global didLoad / loadedAt still carried
            // the PREVIOUS plugin's publish, so the stash
            // wrote 5 section descriptors, empty items and
            // empty errors under another plugin's timestamp.
            // `isLoading` is true from the in-flight load's
            // start until its publish, so requiring
            // !isLoading means a load still in the air can
            // never be stashed — and under that guard outAt
            // truly is the outgoing plugin's own completion
            // time. The write itself goes through the
            // content-free gate (storeSnapshot).
            if let outgoing = loadedPluginId, didLoad, !isLoading, let outAt = loadedAt {
                storeSnapshot(for: outgoing, hero: heroMovie, at: outAt)
            }
            heroMovie = nil
            items = [:]
            sectionErrors = [:]
            sectionPages = [:]
            sectionTotalPages = [:]
            sectionFinished = []
            sectionsLoadingMore = [:]
            lookaheadFocus = [:]
        }
        fillTask?.cancel()
        fillTask = nil
        fillActive = false
        isLoading = true
        loadingPluginId = pid
        let secs = await service.homeSections(pluginId: pid)
        // L-T44 (1.3.17, DESIGN §4.2.5): a superseded load
        // logs its own death — in the evidence session the
        // losing load's section failures were swallowed by
        // the generation guards without a single line, and
        // the session had to be reconstructed from net
        // lines alone. One line per superseded load, at
        // whichever guard exit it takes.
        guard gen == generation else {
            DiagLog.log("home", "load superseded plugin=\(pid) settled=0")
            return false
        }
        sections = secs
        loadedPluginId = pid
        if secs.isEmpty {
            heroMovie = nil
            didLoad = true
            isLoading = false
            loadingPluginId = nil
            loadedAt = Date()
            storeSnapshot(for: pid, hero: nil, at: Date())
            // L-T41 §5.3 (1.3.15): publish line, fresh path
            // (the empty-sections landing) — computed from
            // the published state, like the other two.
            DiagLog.log("home", "publish path=fresh plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil") failed=\(sectionErrors.count)")
            return true
        }
        // Per-section page-1 fetches in parallel; each row
        // publishes as its own fetch lands (the iOS shape).
        // L-T44 (1.3.17, DESIGN §4.2.5): how many section
        // outcomes this load has applied, and whether its
        // superseded line is already written — the two
        // remaining generation-guard exits below share
        // them so a superseded load logs exactly once.
        var settledCount = 0
        var supersedeNoted = false
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
                guard gen == self.generation else {
                    if !supersedeNoted {
                        supersedeNoted = true
                        DiagLog.log("home", "load superseded plugin=\(pid) settled=\(settledCount)")
                    }
                    continue
                }
                settledCount += 1
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
                        // 1.3.19 (S-3): APPEND — the sections land
                        // in parallel and must not evict each
                        // other's pending warm-ups.
                        ImageCacheManager.shared.prefetch(urlStrings: movies.map(\.posterUrl),
                                                          headers: movies.first?.sourcePageURL.map { ["Referer": $0] } ?? [:],
                                                          replace: false)
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
            loadingPluginId = nil
            loadedAt = Date()
            storeSnapshot(for: pid, hero: hero, at: Date())
            // L-T41 §5.3 (1.3.15): publish line, fresh path.
            DiagLog.log("home", "publish path=fresh plugin=\(pid) sections=\(sections.count) items=\(items.values.reduce(0) { $0 + $1.count }) hero=\(heroMovie?.id ?? "nil") failed=\(sectionErrors.count)")
            startBackgroundFill(plugins: plugins, service: service, reason: "publish")
            return true
        }
        // L-T44 (1.3.17, DESIGN §4.2.5): the last guard
        // exit — a generation change after the group
        // drained. (If the change landed mid-group, the
        // loop's guard already wrote the line; the flag
        // keeps it to one.)
        if !supersedeNoted {
            DiagLog.log("home", "load superseded plugin=\(pid) settled=\(settledCount)")
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
    /// `via` (1.3.20) names the caller in the append line:
    /// "fill" (the background head start — no image prefetch,
    /// so a background page never evicts the warm-up of the
    /// posters the user is looking at) or "scroll" (the
    /// focus-driven lookahead). Returns whether the call
    /// appended at least one item.
    @discardableResult
    func loadMoreSection(sectionId: String, plugins: PluginManager, service: MovieService,
                         via: String) async -> Bool {
        let prefetchImages = via != "fill"
        guard let pid = loadedPluginId, pid == plugins.activePlugin?.id else { return false }
        guard let section = sections.first(where: { $0.id == sectionId }) else { return false }
        guard let current = sectionPages[sectionId],
              let total = sectionTotalPages[sectionId] else { return false }
        guard current < total else { return false }
        guard !sectionFinished.contains(sectionId) else { return false }
        guard sectionErrors[sectionId] == nil else { return false }
        guard sectionsLoadingMore[sectionId] == nil else { return false }
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
            guard gen == generation, loadedPluginId == pid else { return false }
            guard sectionPages[sectionId] == current,
                  (items[sectionId]?.count ?? 0) == countAtStart else { return false }
            let existing = items[sectionId] ?? []
            var seen = Set(existing.map(\.id))
            let fresh = result.items.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty {
                items[sectionId] = existing + fresh
                if prefetchImages {
                    ImageCacheManager.shared.prefetch(urlStrings: fresh.map(\.posterUrl),
                                                      headers: fresh.first?.sourcePageURL.map { ["Referer": $0] } ?? [:])
                }
            }
            sectionPages[sectionId] = next
            sectionTotalPages[sectionId] = max(sectionTotalPages[sectionId] ?? total, result.pagination.totalPages)
            if fresh.isEmpty {
                sectionFinished.insert(sectionId)
            }
            DiagLog.log("home", "rail append section=\(section.slug) page=\(next) added=\(fresh.count) total=\(items[sectionId]?.count ?? 0) via=\(via)")
            // 1.3.20 (F-4): the ONLY ways a rail stops growing —
            // the source returned nothing new, or its own last
            // page was reached. One line, so the next log shows
            // the end came from the source, never from the app.
            let totalNow = sectionTotalPages[sectionId] ?? total
            if fresh.isEmpty || next >= totalNow {
                DiagLog.log("home", "rail end section=\(section.slug) page=\(next) totalPages=\(totalNow) total=\(items[sectionId]?.count ?? 0) reason=\(fresh.isEmpty ? "empty" : "lastPage")")
            }
            return !fresh.isEmpty
        } catch {
            DiagLog.log("home", "rail append failed section=\(section.slug) page=\(next) kind=\((error as NSError).domain)#\((error as NSError).code)")
            return false
        }
    }

    /// 1.3.20 (owner addition, ordered 2026-11-27 12:43 CST):
    /// whether a rail append is in flight for this section —
    /// drives the rail-end loading indicator in sectionBand, so
    /// the end of a rail visibly says "still loading" instead of
    /// standing still with no sign of life (his test report:
    /// "kéo hết trang là nó đứng yên chứ ko có vòng tròn
    /// loading"). sectionsLoadingMore is an observed property,
    /// so the band re-renders when an append starts or ends.
    func isPaging(_ sectionId: String) -> Bool {
        sectionsLoadingMore[sectionId] != nil
    }

    /// Whether the section can still page (the same guards
    /// loadMoreSection applies, minus the in-flight marker).
    private func canPage(_ sectionId: String) -> Bool {
        guard let current = sectionPages[sectionId],
              let total = sectionTotalPages[sectionId] else { return false }
        return current < total && !sectionFinished.contains(sectionId) && sectionErrors[sectionId] == nil
    }

    /// L-T42 vòng 3 (1.3.19), revised 1.3.20 (F-3/F-4): pre-load
    /// every horizontal rail of the published plugin to
    /// `fillLookahead` cards in the background — a HEAD START
    /// so the first screens never wait, not the rail's size
    /// (`ensureLookahead` takes over from there as the user
    /// scrolls). Round-robin across rails, one page at a time,
    /// through the same loadMoreSection door the scroll trigger
    /// uses — FL-489 page ownership, dedupe, the finish rule
    /// and the generation guards all apply unchanged. Grid
    /// bands show a fixed 9 cells on Home and are skipped. A
    /// failed page stops that rail only. 300 ms head start for
    /// the visible screen. `reason` is "publish" or "resume"
    /// (a freshness no-op found no fill running).
    func startBackgroundFill(plugins: PluginManager, service: MovieService, reason: String) {
        fillTask?.cancel()
        fillActive = false
        guard let pid = loadedPluginId else { return }
        let gen = generation
        let target = Self.fillLookahead
        let railIds = sections.filter { !$0.isGrid }.map(\.id)
        let wanted = railIds.filter { (items[$0]?.count ?? 0) < target && canPage($0) }
        guard !wanted.isEmpty else { return }
        fillID &+= 1
        let myID = fillID
        fillActive = true
        fillTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.fillID == myID { self.fillActive = false }
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, gen == self.generation, self.loadedPluginId == pid else { return }
            let started = Date()
            let before = self.items.values.reduce(0) { $0 + $1.count }
            DiagLog.log("home", "rail fill start plugin=\(pid) rails=\(wanted.count) lookahead=\(target) items=\(before) reason=\(reason)")
            var active = wanted
            var pages = 0
            while !active.isEmpty {
                var next: [String] = []
                for sid in active {
                    if Task.isCancelled || gen != self.generation || self.loadedPluginId != pid {
                        DiagLog.log("home", "rail fill stopped plugin=\(pid) reason=superseded pages=\(pages)")
                        return
                    }
                    let grew = await self.loadMoreSection(sectionId: sid, plugins: plugins, service: service,
                                                          via: "fill")
                    if grew { pages += 1 }
                    if grew, (self.items[sid]?.count ?? 0) < target, self.canPage(sid) {
                        next.append(sid)
                    }
                }
                active = next
            }
            guard gen == self.generation, self.loadedPluginId == pid else { return }
            let after = self.items.values.reduce(0) { $0 + $1.count }
            DiagLog.log("home", "rail fill done plugin=\(pid) pages=\(pages) items=\(before)->\(after) ms=\(Int(Date().timeIntervalSince(started) * 1000)) handoff=scroll")
        }
    }

    /// 1.3.20 (F-4): the endless rail. Called on EVERY card
    /// focus with the card's index: while fewer than
    /// `scrollLookahead` cards remain after the furthest card
    /// the user has focused in this rail, keep appending the
    /// next page — no app-side cap, the loop ends only when the
    /// user is far enough ahead of the end, the source's own
    /// last page is reached (`rail end`), a page fails, or a
    /// new load supersedes. One loop per rail; a later, deeper
    /// focus just raises the mark the running loop reads. If
    /// the background fill holds the rail's page slot, the loop
    /// waits for it instead of giving up.
    func ensureLookahead(sectionId: String, focusIndex: Int, plugins: PluginManager, service: MovieService) {
        lookaheadFocus[sectionId] = max(lookaheadFocus[sectionId] ?? 0, focusIndex)
        guard !lookaheadRunning.contains(sectionId), canPage(sectionId) else { return }
        guard (items[sectionId]?.count ?? 0) - focusIndex <= Self.scrollLookahead else { return }
        guard let pid = loadedPluginId else { return }
        lookaheadRunning.insert(sectionId)
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.lookaheadRunning.remove(sectionId) }
            var pages = 0
            while !Task.isCancelled, gen == self.generation, self.loadedPluginId == pid, self.canPage(sectionId) {
                let mark = self.lookaheadFocus[sectionId] ?? 0
                guard (self.items[sectionId]?.count ?? 0) - mark <= Self.scrollLookahead else { break }
                if self.sectionsLoadingMore[sectionId] != nil {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                let grew = await self.loadMoreSection(sectionId: sectionId, plugins: plugins, service: service,
                                                      via: "scroll")
                if grew { pages += 1 } else { break }
            }
            if pages > 0 {
                DiagLog.log("home", "rail lookahead section=\(sectionId) pages=\(pages) total=\(self.items[sectionId]?.count ?? 0) focus=\(self.lookaheadFocus[sectionId] ?? 0)")
            }
        }
    }
}

// MARK: - Home view

/// L-T47/L-T48 (1.3.19): whether Home's tab is the SELECTED tab
/// of the root TabView. Home's own appear/disappear lag a tab
/// change by up to a second (log_8: `tab selected=1` at
/// 15:09:37.195, Home's disappear at 15:09:38.244), and a Home
/// that is merely kept alive behind another tab must never run
/// focus side effects — so every focus action on Home is gated
/// on this AND on its own appear state AND on its stack being
/// at root (`TVHomeView.homeVisible`). Set by TVRootView.
private struct TVHomeTabSelectedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var tvHomeTabSelected: Bool {
        get { self[TVHomeTabSelectedKey.self] }
        set { self[TVHomeTabSelectedKey.self] = newValue }
    }
}

struct TVHomeView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var session: PinSession
    @Environment(TVHomeStore.self) private var store
    @Environment(TVNavPath.self) private var nav
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvHomeTabSelected) private var homeTabSelected
    /// 1.3.20: the app-wide engine-focus witness (TVRootView).
    @Environment(TVFocusMonitor.self) private var focusMonitor

    // MARK: Focus model (1.3.19 — L-T47/L-T48 structural rework)
    //
    // The 1.3.15–1.3.18 landing machinery (a landing OBLIGATION
    // with a 4-shot re-fire chain, a settle refresh, a W2 chip-
    // edge guard, a 500 ms watchdog, and a Bool `chipFocused`
    // binding that MIGRATED from chip to chip with the active
    // plugin) is retired. log_8 convicts it twice over:
    //  - every source switch bounced focus chip → PREVIOUS active
    //    chip → back (15:09:11.887, 15:10:24.037, 15:10:42.979,
    //    15:10:56.128): re-attaching the one Bool binding to a
    //    different chip is a focus change SwiftUI resolves on its
    //    own, and at 15:10:56 the bounce parked focus on missav's
    //    chip long enough for missav's DWELL to fire and undo the
    //    user's explicit vlxx select;
    //  - every hero dead-press window (15:10:14.751–19.863,
    //    15:10:44.649–46.566, 15:10:49.919–50.589) opened right
    //    after a PROGRAMMATIC hero landing onto a just-published
    //    content tree; every USER-driven hero gain in the log was
    //    followed by a working press.
    // The rework works WITH the focus engine instead:
    //  - each chip has its OWN stable identity in ONE value-typed
    //    FocusState (`chipFocus == plugin.id`) — nothing migrates;
    //  - Home declares ONE default (`.defaultFocus` → the active
    //    chip), which the engine uses whenever it has to place
    //    focus by itself (a void, a vanished element);
    //  - a source switch moves NOTHING: focus stays on the chip
    //    the user is standing on — the tvOS top-tab idiom — and
    //    one press down enters the new content;
    //  - exactly two programmatic writes remain, each bounded
    //    and each stopping at the first sign of the user: the
    //    COLD landing (launch / PIN return, where the TabView
    //    parks focus on the tab bar — the 1.3.18 park-override,
    //    proven in log_8) and the RETURN landing to the header /
    //    hero the user pushed from;
    //  - one narrow rescue for the tab-bar trap (three dead
    //    presses on the tab bar within 2 s while Home is visible).
    @FocusState private var chipFocus: String?
    @FocusState private var heroFocused: Bool
    /// The section headers' shared value binding — written ONLY
    /// by the return landing.
    @FocusState private var headerFocusSlug: String?

    /// First appear of this view instance (launch, PIN return —
    /// the gate rebuilds the root) runs the cold landing.
    @State private var didColdLanding = false
    /// The element the user is about to push FROM ("header
    /// section=<slug>" / "hero movie=<id>" / "card movie=<id>"),
    /// recorded with the push, consumed by the next appear.
    @State private var pendingReturnElement: String?
    /// Tokenises the landing tasks: any newer landing, a
    /// disappear or a tab change kills the older one.
    @State private var landingGeneration = 0
    @State private var homeAppeared = false
    /// 1.3.20: the dwell's and the rescues' bookkeeping lives in
    /// a plain reference box, NOT in @State. In 1.3.19 every
    /// focus move wrote @State (an epoch counter, the chip-gain
    /// ring, the dwell task) and so re-evaluated the whole Home
    /// body — every rail, every band — on every single press.
    /// None of it is ever displayed.
    @State private var scratch = TVHomeFocusScratch()
    @State private var focusTracker = TVHomeFocusTracker()
    /// 1.3.20 (F-2): the load has shown nothing for
    /// `stallSeconds` — Home shows a focusable, escapable
    /// "source not answering" state instead of a void.
    @State private var loadStalled = false
    @State private var stallGeneration = 0
    private static let stallSeconds = 4
    @State private var lastSilentSyncAt: Date?

    /// Home is the surface the user is actually looking at.
    private var homeVisible: Bool {
        homeAppeared && homeTabSelected && nav.path.isEmpty
    }

    /// The chip the cold landing / rescue aims at: the active
    /// plugin's, or the first visible one if the active id is
    /// not (yet) on the rail.
    private var landingChipId: String? {
        let visible = plugins.visiblePlugins.map(\.id)
        if visible.contains(plugins.activePluginId) { return plugins.activePluginId }
        return visible.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if plugins.visiblePlugins.isEmpty {
                // With no visible plugins the chip rail and
                // content leave the tree; this state's button
                // carries the surface's declared landing itself.
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
        // The ONE default-focus declaration on Home: whenever the
        // engine must place focus itself, it goes to the active
        // chip — the top of the screen, never a half-built band.
        .defaultFocus($chipFocus, landingChipId)
        .onAppear {
            session.touch()
            focusTracker.install()
            focusTracker.beginAppearance()
            focusTracker.onTabBarMoveFail = { handleTabBarDeadPress() }
            homeAppeared = true
            DiagLog.log("home", "appear tabSelected=\(homeTabSelected) depth=\(nav.path.count)")
            // 1.3.20 (F-1/F-2): make sure UP from the top row
            // reaches the tab bar (idempotent; re-points after a
            // PIN-return rebuild).
            TVTabBarFocusBridge.install(reason: "home-appear")
            armStallWatch()
            if !didColdLanding {
                didColdLanding = true
                runColdLanding()
                logLanding(target: "chip")
            } else if let returning = pendingReturnElement, nav.path.isEmpty {
                pendingReturnElement = nil
                runReturnLanding(returning)
                logLanding(target: "return element=\(returning)")
            }
        }
        .onDisappear {
            homeAppeared = false
            landingGeneration &+= 1
            DiagLog.log("home", "disappear")
            cancelChipDwell()
            focusTracker.onTabBarMoveFail = nil
            focusTracker.uninstall()
        }
        // 1.3.20 (F-2): a focus VOID on Home (the engine has no
        // focused item at all) that lasts 400 ms is rescued onto
        // the active chip — focus is never left without a
        // destination.
        .onChange(of: focusMonitor.voidEpoch) { _, epoch in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard epoch == focusMonitor.voidEpoch, focusMonitor.place == .nowhere,
                      homeVisible, let target = landingChipId else { return }
                DiagLog.log("focus", "void-rescue surface=home target=chip plugin=\(target)")
                chipFocus = target
            }
        }
        .onChange(of: store.isLoading) { _, _ in armStallWatch() }
        .onChange(of: contentHasBands) { _, _ in armStallWatch() }
        .onChange(of: homeTabSelected) { _, selected in
            // Leaving the tab kills every pending focus action
            // at once (the appear/disappear pair lags the tab
            // change by up to a second).
            if !selected {
                landingGeneration &+= 1
                cancelChipDwell()
            }
        }
        .task {
            if plugins.installed.isEmpty {
                await plugins.syncAll()
                lastSilentSyncAt = Date()
            } else if lastSilentSyncAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                // 1.3.19 (scan finding S-4): the silent source sync
                // ran on EVERY Home appear — each pop-back from a
                // Category/Detail and each tab return re-fetched
                // plugins.json (log_8: 7 `[sync] start` lines in
                // 3 minutes). Once per 5 minutes per Home instance
                // is plenty; launch and PIN return (a new
                // instance) still sync at once.
                lastSilentSyncAt = Date()
                Task { await plugins.syncAll(silent: true) }
            }
            await store.load(plugins: plugins, service: service)
        }
        .onChange(of: plugins.activePluginId) { _, newId in
            // L-T48 (b)/(c): a switch is a DATA change only —
            // the new source loads, focus stays exactly where
            // the user is (the chip). It may arrive from any
            // cause (a chip select or dwell here, the Category
            // tab's own chip rail while Home is hidden); none of
            // them moves focus. `visible=` records which case
            // the next log shows.
            cancelChipDwell()
            DiagLog.log("home", "switch plugin=\(newId) visible=\(homeVisible) tracker=\(focusTracker.current)")
            Task { await store.load(plugins: plugins, service: service) }
            armStallWatch()
        }
        .onChange(of: plugins.syncGeneration) { _, _ in
            // A sync settle reloads data only (freshness rules
            // in the store make it a no-op while fresh).
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
                           selected: plugin.id == plugins.activePluginId,
                           // 1.3.19: a STABLE per-chip identity in
                           // one value FocusState — this chip is
                           // focused exactly when chipFocus holds
                           // its id. Nothing re-binds on a switch.
                           valueFocus: $chipFocus,
                           focusID: plugin.id,
                           onFocusChange: { focused in
                               focusHook("chip plugin=\(plugin.id)")(focused)
                               noteChipDwell(pluginId: plugin.id, focused: focused)
                           }) {
                        cancelChipDwell()
                        plugins.activePluginId = plugin.id
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 18)
        }
        .focusSection()
    }

    private var content: some View {
        ScrollView {
            // A plain VStack, not a LazyVStack (L-T41 §5.2): on
            // tvOS scrolling is a side effect of focus movement,
            // and an unrealized band is a focus target that does
            // not exist yet. The real laziness lives INSIDE the
            // rails (LazyHStack tails) and grids.
            VStack(alignment: .leading, spacing: 44) {
                if let hero = store.heroMovie, let pid = plugins.activePlugin?.id {
                    heroBand(hero: hero, pluginId: pid)
                }
                if !history.continueWatching.isEmpty {
                    continueWatchingBand
                        .focusSection()
                }
                // A-10 (1.3.9) + design pass D-5: the poster
                // bands' long-press hint, stated once.
                if plugins.activePlugin != nil,
                   store.sections.contains(where: { !(store.items[$0.id] ?? []).isEmpty }) {
                    Text("Giữ lâu một thẻ để ghim / bỏ ghim yêu thích")
                        .font(.system(size: 23))
                        .foregroundStyle(theme.textDim)
                }
                ForEach(store.sections) { section in
                    if store.sectionErrors[section.id] != nil, (store.items[section.id] ?? []).isEmpty {
                        // The all-error band holds ONE focusable
                        // (the retry button) — no section wrapper.
                        sectionBand(section)
                    } else if !(store.items[section.id] ?? []).isEmpty {
                        sectionBand(section)
                            .focusSection()
                    }
                }
                // 1.3.20 (F-2): the empty/loading/stalled states key
                // off whether ANY band is on screen, not off
                // `sections.isEmpty`. In 1.3.19 a switch set the new
                // plugin's section list before any section had
                // landed, so `sections` was non-empty while nothing
                // rendered: no spinner, no empty state, no
                // focusable — a void below the chips for as long as
                // the source took (a dead source: Net's full 20 s
                // budget per section). A load that settled with
                // every section empty and error-free left the same
                // void forever.
                if store.didLoad && !contentHasBands && !store.isLoading {
                    TVEmptyState(icon: "film.stack", title: "Chưa có nội dung",
                                 actionTitle: "Tải lại",
                                 action: { Task { await store.load(plugins: plugins, service: service, force: true) } },
                                 onFocusChange: focusHook("empty action=reload"))
                        .onMoveCommand { direction in escapeToChip(from: "empty", direction) }
                } else if store.isLoading && !contentHasBands && loadStalled {
                    TVEmptyState(icon: "wifi.exclamationmark", title: "Nguồn chưa phản hồi",
                                 message: "Máy chủ của nguồn này đang chậm hoặc không trả lời.",
                                 actionTitle: "Tải lại",
                                 action: { Task { await store.load(plugins: plugins, service: service, force: true) } },
                                 onFocusChange: focusHook("empty action=stalled-reload"))
                        .onMoveCommand { direction in escapeToChip(from: "stalled", direction) }
                } else if store.isLoading && !contentHasBands {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 48)
        }
        // The scroll region is one focus section, so the step
        // from the pinned chip rail into the bands always has a
        // section frame to search.
        .focusSection()
    }

    // MARK: - Focus diagnostics (L-T41 §5.3, kept)

    /// One hook body for every focusable Home element: a
    /// gain/lost line per transition plus the tracker's
    /// current-owner note that the moveFail and landing lines
    /// read. Only element kinds and ids are logged.
    private func focusHook(_ element: String) -> (Bool) -> Void {
        { focused in
            if focused {
                focusTracker.note(element)
                DiagLog.log("focus", "home gain element=\(element)")
            } else {
                focusTracker.clear(if: element)
                DiagLog.log("focus", "home lost element=\(element)")
            }
        }
    }

    // MARK: - Dwell-to-switch (L-T45 1.3.18, revised 1.3.19)

    private func cancelChipDwell() {
        scratch.dwellTask?.cancel()
        scratch.dwellTask = nil
        scratch.dwellPluginId = nil
    }

    /// A chip that HOLDS focus switches the source by itself
    /// (L-T45: the owner's natural gesture is land-on-chip,
    /// press-down). 1.3.19 (L-T48 (b)): the dwell must not fire
    /// on the last pause of a fast traversal — log_8 15:10:42.917
    /// fired sayhentai after a 604 ms pause that ended a 7-chip,
    /// ~2 s walk, and the load was thrown away 0.8 s later. The
    /// rule, kept deliberately simple:
    ///  - a chip reached by a SINGLE step (fewer than two other
    ///    chip gains in the 1.2 s before it) switches after the
    ///    proven 600 ms;
    ///  - a chip reached at the end of a TRAVERSAL (two or more
    ///    chip gains in the 1.2 s before it) must be held for
    ///    1300 ms — longer than any end-of-walk hesitation the
    ///    owner produced (≤ ~0.65 s in log_8), while a genuine
    ///    stop still switches on its own within ~1.3 s, and
    ///    Select switches at once either way.
    /// Every log_8 dwell the owner meant (123av 15:09:11.811,
    /// avdbapi 15:10:13.776, 123av 15:10:23.946, avdbapi
    /// 15:10:49.572) was a single step and keeps its 600 ms.
    /// FIRE conditions: still the armed dwell, the tracker still
    /// names this chip, not already active, Home visible.
    /// 1.3.20 (F-2): the 1.3.19 "no focus event since the arm"
    /// epoch condition is GONE. SwiftUI delivers a chip-to-chip
    /// move as gain-then-lost about half the time (log_9
    /// 11:58:43.987: `gain chip avdbapi` / `lost chip 123av` in
    /// the same millisecond); the old chip's LOST arrived after
    /// the arm, bumped the epoch, and the dwell silently never
    /// fired — the owner sat on avdbapi's chip for 2.8 s and
    /// nothing happened. A loss of THIS chip still cancels the
    /// dwell (below), and any other chip's gain re-arms it, so
    /// the epoch added nothing but the race.
    private func noteChipDwell(pluginId: String, focused: Bool) {
        if focused {
            let now = Date()
            let recent = scratch.recentChipGains.filter { now.timeIntervalSince($0) <= 1.2 }
            scratch.recentChipGains = Array((recent + [now]).suffix(6))
            cancelChipDwell()
            guard pluginId != plugins.activePluginId, homeVisible else { return }
            let traversal = recent.count >= 2
            let threshold = traversal ? 1300 : 600
            scratch.dwellPluginId = pluginId
            scratch.dwellTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(threshold))
                guard !Task.isCancelled,
                      scratch.dwellPluginId == pluginId,
                      focusTracker.current == "chip plugin=\(pluginId)",
                      pluginId != plugins.activePluginId,
                      homeVisible
                else { return }
                scratch.dwellTask = nil
                scratch.dwellPluginId = nil
                let dwellMs = Int(Date().timeIntervalSince(now) * 1000)
                DiagLog.log("focus", "dwell switch plugin=\(pluginId) dwell=\(dwellMs)ms threshold=\(threshold)ms traversal=\(traversal ? "yes" : "no")")
                plugins.activePluginId = pluginId
            }
        } else if scratch.dwellPluginId == pluginId {
            cancelChipDwell()
        }
    }

    // MARK: - 1.3.20 (F-2): no dead ends, no voids

    /// Whether any band is actually on screen (a hero, a rail
    /// with items, or a section's error row).
    private var contentHasBands: Bool {
        if store.heroMovie != nil { return true }
        return store.sections.contains { section in
            !(store.items[section.id] ?? []).isEmpty || store.sectionErrors[section.id] != nil
        }
    }

    /// The full-surface states (empty / stalled) hold ONE
    /// button, and the `.onMoveCommand` on it consumes every
    /// direction — the engine's own search does not also run,
    /// so no direction "reaches the chips by itself". Instead
    /// of eating the press, all four directions hand focus
    /// back to the active chip — the state can be left in
    /// every direction. (Gate fix, 1.3.20: the `.up` exemption
    /// in the first draft of this function made Up a dead
    /// press here; two gate lenses convicted it independently.)
    private func escapeToChip(from state: String, _ direction: MoveCommandDirection) {
        guard homeVisible, let target = landingChipId else { return }
        DiagLog.log("focus", "empty-escape state=\(state) dir=\(String(describing: direction)) target=chip plugin=\(target)")
        chipFocus = target
    }

    /// Arms (or disarms) the stall watch: a load that has put
    /// nothing on screen for `stallSeconds` flips `loadStalled`.
    private func armStallWatch() {
        stallGeneration &+= 1
        let gen = stallGeneration
        if loadStalled { loadStalled = false }
        if !store.isLoading || contentHasBands { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.stallSeconds))
            guard gen == stallGeneration, store.isLoading, !contentHasBands else { return }
            loadStalled = true
            DiagLog.log("home", "load stalled plugin=\(plugins.activePluginId) after=\(Self.stallSeconds)s state=focusable-empty")
        }
    }

    // MARK: - Landings (1.3.19 — the two remaining writes)

    /// COLD landing: launch and PIN return. The TabView parks
    /// focus on the tab bar on a fresh root; this lands it on the
    /// active chip. Shots at +0/+150/+500/+1200 ms (the measured
    /// cold tail), each skipped the moment the user has touched
    /// anything in this appearance (any Home gain or loss, or a
    /// dead press on the tab bar) or Home stops being visible.
    private func runColdLanding() {
        landingGeneration &+= 1
        let gen = landingGeneration
        Task { @MainActor in
            var elapsed = 0
            for (n, offset) in [0, 150, 500, 1200].enumerated() {
                if offset > elapsed {
                    try? await Task.sleep(for: .milliseconds(offset - elapsed))
                    elapsed = offset
                }
                guard gen == landingGeneration, homeVisible,
                      !focusTracker.userHasTakenFocus,
                      let target = landingChipId else { return }
                let engine = TVFocusProbe.engineFocus()
                DiagLog.log("focus", "landing shot cold n=\(n) target=chip plugin=\(target) engine=\(engine.label) item=\(engine.description)")
                chipFocus = target
            }
        }
    }

    /// RETURN landing after a pop / tab return: back onto the
    /// header or hero the user pushed from. Usually the engine's
    /// own restore delivers it first (then the user-has-focus
    /// gate stops every shot); a card has no binding and is
    /// always left to the restore. Shots at +150/+500 ms only.
    private func runReturnLanding(_ descriptor: String) {
        landingGeneration &+= 1
        let gen = landingGeneration
        guard descriptor.hasPrefix("header section=") || descriptor.hasPrefix("hero") else { return }
        Task { @MainActor in
            var elapsed = 0
            for (n, offset) in [150, 500].enumerated() {
                try? await Task.sleep(for: .milliseconds(offset - elapsed))
                elapsed = offset
                guard gen == landingGeneration, homeVisible,
                      !focusTracker.userHasTakenFocus else { return }
                DiagLog.log("focus", "landing shot return n=\(n) target=\(descriptor) engine=\(TVFocusProbe.engineFocus().label)")
                if descriptor.hasPrefix("header section=") {
                    headerFocusSlug = String(descriptor.dropFirst("header section=".count))
                } else if store.heroMovie != nil {
                    heroFocused = true
                }
            }
        }
    }

    /// L-T48 (d): the tab-bar trap (log_8 15:09:34.861–36.400:
    /// four dead presses on `Trang_chủ` until he escaped by
    /// changing tab). On the tab bar, Up (nothing above) or Left
    /// on the first tab are normal dead presses, so one or two
    /// prove nothing; THREE within 2 s while Home is the visible
    /// tab means the user is pressing down and the engine is not
    /// entering Home (the trap produced 3 in 0.98 s) — land on
    /// the active chip once, and log it.
    private func handleTabBarDeadPress() {
        let now = Date()
        scratch.tabBarDeadPresses = scratch.tabBarDeadPresses.filter { now.timeIntervalSince($0) <= 2.0 } + [now]
        guard scratch.tabBarDeadPresses.count >= 3, homeVisible, let target = landingChipId else { return }
        scratch.tabBarDeadPresses = []
        DiagLog.log("focus", "tabbar-rescue target=chip plugin=\(target)")
        chipFocus = target
    }

    /// The landing audit lines (kept): which element SHOULD hold
    /// focus after an entry vs the owner the hooks reported, at
    /// +300 ms and +1200 ms. Logged only while Home is visible.
    private func logLanding(target: String) {
        for late in [300, 1200] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(late))
                guard homeVisible else { return }
                DiagLog.log("focus", "landing scope=home target=\(target) actual=\(focusTracker.current) late=\(late)ms")
            }
        }
    }

    private func heroBand(hero: Movie, pluginId: String) -> some View {
        TVHeroCard(movie: hero,
                   onSelect: {
                       pendingReturnElement = "hero movie=\(hero.id)"
                       nav.push(.movie(MovieRoute(pluginId: pluginId, movie: hero, autoResume: false)))
                   },
                   onFocusChange: focusHook("hero movie=\(hero.id)"),
                   entryFocus: $heroFocused)
    }

    /// One rail card. 1.3.20 (F-4): every card focus feeds the
    /// rail's endless lookahead (`ensureLookahead`) — pages keep
    /// arriving `scrollLookahead` cards ahead of the user until
    /// the source's own last page.
    private func railCard(movie: Movie, pluginId pid: String, section: HomeSection,
                          globalIndex index: Int, totalCount: Int) -> some View {
        TVPosterCard(movie: movie, width: 240,
                     isFavorite: favorites.isFavorite(pluginId: pid, movieId: movie.id),
                     onSelect: {
                         pendingReturnElement = "card movie=\(movie.id)"
                         nav.push(.movie(MovieRoute(pluginId: pid, movie: movie)))
                     },
                     onLongPress: {
                         favorites.toggle(pluginId: pid, movie: movie)
                     },
                     onFocusChange: { focused in
                         focusHook("card movie=\(movie.id)")(focused)
                         if focused {
                             // 1.3.20 (F-4): endless — keep a
                             // lookahead of loaded cards past
                             // this one, to the source's end.
                             store.ensureLookahead(sectionId: section.id, focusIndex: index,
                                                   plugins: plugins, service: service)
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
                            // Return-landing origin record
                            // (DESIGN §2.2.2), as in heroBand.
                            pendingReturnElement = "card movie=\(record.movie.id)"
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
                                      Task { await store.load(plugins: plugins, service: service, force: true) }
                                  },
                                  onFocusChange: focusHook("retry section=\(section.slug)"))
            }
        } else if !movies.isEmpty, let pid = plugins.activePlugin?.id {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader(title: section.title,
                                action: {
                                    // Record the push origin —
                                    // THIS header — for the
                                    // return landing on pop.
                                    pendingReturnElement = "header section=\(section.slug)"
                                    nav.push(.category(CategoryRoute(pluginId: pid, slug: section.slug,
                                                                     title: section.title, filters: ListFilters())))
                                },
                                onFocusChange: focusHook("header section=\(section.slug)"),
                                focusSlug: section.slug,
                                entryFocus: $headerFocusSlug)
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
                            if store.isPaging(section.id) {
                                // 1.3.20 (owner addition, ordered
                                // 2026-11-27 12:43 CST): rail-end
                                // loading indicator. While the next
                                // page is in flight, the end of the
                                // rail shows a spinner instead of
                                // standing still, so "still loading"
                                // is distinguishable from "the
                                // source has ended". Deliberately
                                // NOT focusable: the focus engine
                                // skips it and focus stays on the
                                // last card; it disappears the
                                // moment the append lands (or the
                                // attempt ends).
                                ProgressView()
                                    .frame(width: 120)
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

// MARK: - Focus scratch (1.3.20)

/// Home's non-displayed focus bookkeeping. A plain reference
/// (not Observable), held in @State only for its lifetime, so
/// writing it never re-evaluates Home's body. Main actor only.
@MainActor
private final class TVHomeFocusScratch {
    var dwellTask: Task<Void, Never>?
    var dwellPluginId: String?
    /// Gain times of the last few chip gains — the traversal
    /// witness the dwell threshold reads.
    var recentChipGains: [Date] = []
    /// Times of recent dead presses on the tab bar (rescue).
    var tabBarDeadPresses: [Date] = []
}

// MARK: - Focus tracker (L-T41 §5.3, simplified 1.3.19)

/// Owns Home's passive focus-movement-failure observer and the
/// last focus owner the view's hooks reported.
///
/// The observer is PASSIVE: it only listens for
/// `UIFocusSystem.movementDidFailNotification` — the engine's
/// own broadcast when a remote press finds no candidate — and
/// writes one DiagLog line pairing the failure with BOTH
/// witnesses: the engine's `focusedItem` (TVFocusProbe) and the
/// element the hooks say held focus (`tracker=`). A dead press
/// whose engine reading is the TAB BAR is also handed to the
/// view (`onTabBarMoveFail`) for the tab-bar rescue.
///
/// `userHasTakenFocus` separates the shell's cold-start tab-bar
/// PARK (nothing touched yet in this appearance) from the user
/// actually holding focus: set by any Home gain, any Home loss
/// that clears the owner, and any tab-bar dead press; reset by
/// `beginAppearance()` on every Home appear. The cold and return
/// landings stop at it.
///
/// Concurrency (the FL-495 discipline): all state is instance
/// state behind `lock`, hence `@unchecked Sendable`.
private final class TVHomeFocusTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = "none"
    private var _userHasTakenFocus = false
    private var token: NSObjectProtocol?
    /// Main-actor callback for a dead press on the tab bar;
    /// set by the view on appear, cleared on disappear. Read
    /// and written on the main actor only.
    @MainActor var onTabBarMoveFail: (@MainActor () -> Void)?

    var current: String {
        lock.withLock { _current }
    }

    var userHasTakenFocus: Bool {
        lock.withLock { _userHasTakenFocus }
    }

    func beginAppearance() {
        lock.withLock { _userHasTakenFocus = false }
    }

    func note(_ element: String) {
        lock.withLock {
            _current = element
            _userHasTakenFocus = true
        }
    }

    func clear(if element: String) {
        lock.withLock {
            if _current == element {
                _current = "none"
                _userHasTakenFocus = true
            }
        }
    }

    func install() {
        let shouldRegister = lock.withLock { token == nil }
        guard shouldRegister else { return }
        let newToken = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.movementDidFailNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let engine = TVFocusProbe.engineFocus()
                let onTabBar = engine.state == .onTabBar
                if onTabBar {
                    self.lock.withLock { self._userHasTakenFocus = true }
                }
                DiagLog.log("focus", "moveFail focusedItem=\(engine.description) tracker=\(self.current)")
                if onTabBar { self.onTabBarMoveFail?() }
            }
        }
        lock.withLock { token = newToken }
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
