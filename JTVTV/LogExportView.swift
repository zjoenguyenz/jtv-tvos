import CoreImage
import Foundation
import Network
import SwiftUI
import UIKit

// MARK: - LAN log export (LOG RETRIEVAL LAW; JoeTV pattern)
//
// tvOS has no share sheet, no activity view and no file
// exporter (Apple HIG: activity views are not supported on
// tvOS; ShareLink / UIActivityViewController do not compile
// there), so — exactly as in JoeTV tvOS — the log leaves the
// box over the home LAN: while THIS screen is open, a tiny
// HTTP server serves JTV's DiagLog export text at one address;
// the screen shows that address in large type and as a QR
// code, and the owner's iPhone downloads the file in Safari.
//
// Access shape (the owner's accepted JoeTV design, register
// R-63): the address carries a random 6-digit token IN ITS
// PATH — http://<LAN-IP>:18080/<token>/jtv-log.txt — minted
// fresh every time the screen opens. The server serves ONLY
// that exact path; every other request gets a 404 and no
// content. The server lives only while the screen is open
// (start on appear, stop on disappear).
//
// Brute-force hardening (mirrors JoeTV's DiagLogServer,
// v2.0.40 / R3-1): 3 consecutive wrong-path requests pause
// the channel for 60 seconds. The attempt counter lives on
// this server class and the lockout deadline is a STATIC
// (class-level) stored property, so the pause survives the
// screen being dismissed and reopened — the only restart
// path that exists. While locked, `start()` refuses with a
// .failed state and `handle` refuses every request, even
// one carrying the correct path, with the same bare 404.
//
// The body served is `DiagLog.exportText()` verbatim: JTV's
// DiagLog is redacted by construction (call sites log hosts
// and outcomes, never credential values), and nothing is
// added to it here. The token and the serving URL are never
// written to the log.
//
// Phase C (L-T02, Diagnosis §4.2/§4.3): this screen is now
// presented by fullScreenCover from Settings (not a
// NavigationLink push), so it carries no navigation chrome —
// the in-body title above is the screen's title. The server
// gained the process-level port gate documented at the class
// below: single owner for port 18080, rebind gated on the
// previous listener's .cancelled, allowLocalEndpointReuse as
// adjunct only, and per-instance transition logging. Port,
// token model, lockout and serving behaviour are unchanged.

/// The one-file HTTP server behind LogExportView.
///
/// Swift 6: @MainActor, following JoeTV's proven DiagLogServer
/// shape — the listener, the live-connection table and the
/// state callback are touched ONLY on the main actor. Network
/// handlers are @Sendable closures on the server's private
/// serial queue; each captures only Sendable values plus a
/// weak self and hops back with `Task { @MainActor in }`
/// before touching state, so the class needs no unchecked
/// Sendable conformance and no NSLock.
@MainActor
final class JTVLogExportServer {

    enum State {
        case starting
        case serving(url: String)
        case failed(String)
    }

    /// State observer — set by the view before `start()`.
    /// Always invoked on the main actor.
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "jtvtv.logexport.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// This session's random token (6 digits), minted by every
    /// `start()`. Read by the view to display it on its own
    /// line as well as inside the URL/QR.
    private(set) var token = ""

    /// The exact path the one file is served at.
    private var expectedPath: String { "/\(token)/jtv-log.txt" }

    /// Consecutive wrong-path requests since the last success.
    private var failedAttempts = 0

    /// After 3 consecutive wrong paths the channel refuses to
    /// serve until this instant (the 60-second lockout).
    /// STATIC on purpose (mirrors JoeTV's R3-1 fix): this
    /// server instance is owned by LogExportView's @State, and
    /// dismissing the screen destroys that state —
    /// an instance deadline would die with the screen, and the
    /// failure message itself tells the owner to close and
    /// reopen it. The deadline must live at class level so the
    /// promised 60-second pause survives the only restart path
    /// that exists; reopening inside the window reports
    /// .failed, reopening after it serves with a fresh token.
    /// Main-actor isolation comes from the class.
    private static var lockoutUntil: Date?

    // MARK: Process-level port ownership (Phase C, Diagnosis §4.3.2/§4.3.3)
    //
    // Port 18080 is a PROCESS-wide resource, but this server is
    // owned per view instance (@State in LogExportView) — an
    // instance-only `listener == nil` guard cannot stop a
    // second instance binding over a first instance's live
    // listener, nor a rebind racing a previous listener's
    // asynchronous cancel (cancel() has NO synchronous-release
    // guarantee; the documented completion signal is the
    // .cancelled state delivery — Ch.3 §2.3). This gate is the
    // single process-level owner: it records the identity of
    // the one live listener and of a listener that is still
    // cancelling. The gate's cancelling entry clears ONLY when
    // that listener's stateUpdateHandler delivers .cancelled
    // with the matching identity (§4.3.3) — and that clearing
    // is INSTANCE-INDEPENDENT: terminal-state gate updates run
    // through the static helpers below, invoked from the
    // handler's main-actor Task whether or not the owning
    // instance still exists. The instance is owned by the
    // view's @State and can deinit after stop() but before
    // .cancelled is delivered; a dismissed screen's teardown
    // still completes, because the handler keeps the listener
    // (and its identity) alive on its own. Statics here are
    // main-actor isolated state of this @MainActor class
    // (Ch.4 §20.1 legal shape) — no locks, no unchecked
    // conformances.
    private static var gateLiveID: ObjectIdentifier?
    private static var gateCancellingID: ObjectIdentifier?

    /// True while any listener in the process is live on
    /// 18080 or still tearing down.
    private static var gateBusy: Bool {
        gateLiveID != nil || gateCancellingID != nil
    }

    /// Terminal-state gate bookkeeping for .cancelled,
    /// performed STATICALLY so it never depends on the owning
    /// instance still being alive: the instance is owned by
    /// LogExportView's @State, and on cover dismissal stop()
    /// runs and the instance can deinit BEFORE the framework
    /// delivers .cancelled — a weak-self hop would then drop
    /// the delivery and leave the gate busy forever. The
    /// listener's stateUpdateHandler captures the listener
    /// strongly, so its identity is available in the handler's
    /// main-actor Task even when the instance is gone, and the
    /// gate fields live at class level, so clearing them needs
    /// no instance. Clears ONLY on identity match (§4.3.3).
    /// This static context has no instance tag, so the
    /// gate-cleared line is logged without one — never the
    /// token, never the URL.
    private static func noteListenerCancelled(id: ObjectIdentifier) {
        guard gateCancellingID == id || gateLiveID == id else { return }
        if gateLiveID == id { gateLiveID = nil }
        if gateCancellingID == id { gateCancellingID = nil }
        DiagLog.log("logexport", "listener cancelled — port gate cleared")
    }

    /// Terminal-state gate bookkeeping for .failed: the same
    /// instance-independence as noteListenerCancelled — the
    /// live-gate entry is cleared on identity match even if
    /// the owning instance has already been destroyed.
    /// Instance-level .failed handling (surfacing, EADDRINUSE
    /// retry) stays in listenerStateChanged for the alive
    /// path; this helper owns ONLY the gate field.
    private static func noteListenerFailed(id: ObjectIdentifier) {
        if gateLiveID == id { gateLiveID = nil }
        if gateCancellingID == id { gateCancellingID = nil }
    }

    /// Short per-instance ID tagged onto every transition log
    /// line (§4.3.6), so a recurrence of the NWError-48 fault
    /// is discriminable between mechanisms from the exported
    /// log itself. Never the token, never the URL.
    private let instanceTag = String(UUID().uuidString.prefix(8))

    /// True between a start() request and stop(): a deferred
    /// or retried bind may only proceed while this holds.
    private var wantsServing = false

    /// Bounded EADDRINUSE backstop retries (§4.3.3): a bind
    /// that still lands in .failed with address-in-use gets
    /// this many fresh attempts before .failed is surfaced.
    private var bindRetries = 0
    private static let maxBindRetries = 3

    /// The pending deferred/retry bind, if any. Stored so
    /// stop() can cancel it; it captures only a weak self and
    /// touches nothing after the instance is gone.
    private var pendingBindTask: Task<Void, Never>?

    /// Deadline for a deferred bind: set when a start first
    /// defers behind a busy port gate, cleared on bind and on
    /// stop(). Bounds the total deferral to 30 seconds (see
    /// schedulePendingBind).
    private var deferDeadline: Date?

    func start() {
        DiagLog.log("logexport", "[\(instanceTag)] start requested")
        if let until = Self.lockoutUntil, until > Date() {
            emit(.failed("Kênh gửi log đang tạm dừng sau 3 lần nhập sai mã — chờ khoảng 1 phút rồi mở lại màn hình này."))
            return
        }
        guard listener == nil else { return }
        guard pendingBindTask == nil else { return }
        wantsServing = true
        bindRetries = 0
        token = String(format: "%06d", Int.random(in: 0...999_999))
        failedAttempts = 0
        emit(.starting)
        if Self.gateBusy {
            // Another instance's listener is live or still
            // cancelling: this start must NOT bind (§4.3.2).
            // Defer on the main actor until the gate clears;
            // the view state stays .starting meanwhile.
            DiagLog.log("logexport", "[\(instanceTag)] start deferred — port gate busy")
            schedulePendingBind(after: .milliseconds(250))
            return
        }
        bindNow()
    }

    /// Construct and start a FRESH NWListener (§4.3.1: every
    /// start constructs a new listener; a cancelled or failed
    /// listener is never restarted). Callers guarantee the
    /// port gate is clear and this instance has no listener.
    private func bindNow() {
        guard wantsServing, listener == nil else { return }
        deferDeadline = nil
        guard let port = NWEndpoint.Port(rawValue: 18080) else {
            emit(.failed("Không mở được kênh gửi log (cổng không hợp lệ)."))
            return
        }
        let parameters = NWParameters.tcp
        // §4.3.4 adjunct ONLY, set BEFORE listener creation.
        // Limits (Ch.3 §2.5): allowLocalEndpointReuse permits
        // reuse of a LINGERING local endpoint (TIME_WAIT
        // class); it does NOT evict or share a live listener,
        // does NOT make cancel() synchronous, and does NOT
        // substitute for the gate above or the .cancelled
        // wait — those remain the actual fix.
        parameters.allowLocalEndpointReuse = true
        let created: NWListener
        do {
            created = try NWListener(using: parameters, on: port)
        } catch {
            DiagLog.log("logexport", "[\(instanceTag)] listener construction failed")
            emit(.failed("Không mở được kênh gửi log: \(error.localizedDescription)"))
            return
        }
        // Claim the port gate synchronously, before start, so
        // no other instance can slip a bind in between.
        Self.gateLiveID = ObjectIdentifier(created)
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                // Terminal-state GATE clearing runs FIRST and
                // does NOT route through the weak self: this
                // handler captures `created` strongly, so the
                // listener and its identity outlive the server
                // instance, which the view's @State can destroy
                // after stop() but before .cancelled arrives.
                // The static helpers own the gate fields, so
                // the gate clears even when self is already
                // nil; instance-level handling then follows
                // via self? exactly as before.
                switch state {
                case .cancelled:
                    Self.noteListenerCancelled(id: ObjectIdentifier(created))
                case .failed:
                    Self.noteListenerFailed(id: ObjectIdentifier(created))
                default:
                    break
                }
                self?.listenerStateChanged(state, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
    }

    /// Main-actor polling behind a deferred start or an
    /// EADDRINUSE retry (§4.3.3): waits until the port gate
    /// clears, then binds. The deferral is bounded by a total
    /// budget of 30 seconds from the first deferral
    /// (deferDeadline, aligned to the Ch.5 §2.2 measured
    /// worst case of ~26–30 s): if the budget is exhausted
    /// while the gate is still busy, polling stops, one
    /// timeout line is logged, and a terminal .failed is
    /// emitted — it never binds over a busy gate. No
    /// continuations, no locks. The task is stored so stop()
    /// can cancel it, and it holds only a weak self.
    private func schedulePendingBind(after delay: Duration) {
        if deferDeadline == nil {
            deferDeadline = Date().addingTimeInterval(30)
        }
        pendingBindTask?.cancel()
        pendingBindTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingBindTask = nil
            guard self.wantsServing, self.listener == nil else { return }
            if Self.gateBusy {
                if let deadline = self.deferDeadline, Date() >= deadline {
                    self.deferDeadline = nil
                    DiagLog.log("logexport", "[\(self.instanceTag)] start deferred timeout — port gate still busy after 30s")
                    self.emit(.failed("Kênh gửi log lỗi: cổng gửi log đang bận — đóng màn hình này, chờ một chút rồi mở lại."))
                    return
                }
                self.schedulePendingBind(after: .milliseconds(250))
                return
            }
            self.bindNow()
        }
    }

    /// Cancel the listener and every live connection — the
    /// server never outlives its screen. The cancelling
    /// listener's identity is RECORDED in the port gate
    /// (§4.3.3): the gate clears only when that listener's
    /// .cancelled is delivered, so a later start can never
    /// rebind over a teardown still in flight.
    func stop() {
        wantsServing = false
        deferDeadline = nil
        pendingBindTask?.cancel()
        pendingBindTask = nil
        if let live = listener {
            let id = ObjectIdentifier(live)
            if Self.gateLiveID == id { Self.gateLiveID = nil }
            Self.gateCancellingID = id
            DiagLog.log("logexport", "[\(instanceTag)] listener cancelling")
            live.cancel()
            listener = nil
        }
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
    }

    // MARK: Listener / connection handling (main actor)

    private func listenerStateChanged(_ state: NWListener.State,
                                      listener: NWListener) {
        let id = ObjectIdentifier(listener)
        switch state {
        case .ready:
            DiagLog.log("logexport", "[\(instanceTag)] listener bound on 18080")
            guard let ip = Self.lanIPAddress(), let port = listener.port else {
                emit(.failed("Không tìm thấy địa chỉ mạng nội bộ."))
                return
            }
            emit(.serving(url: "http://\(ip):\(port.rawValue)\(expectedPath)"))
        case .failed(let error):
            if self.listener === listener { self.listener = nil }
            if Self.gateLiveID == id { Self.gateLiveID = nil }
            // Backstop only (§4.3.3): a bind that still lands
            // in .failed with EADDRINUSE — e.g. a holder
            // outside this process's gate — gets a bounded
            // number of fresh attempts with short waits before
            // the failure is surfaced. The failed listener
            // itself is released, never restarted (§4.3.5).
            if wantsServing, bindRetries < Self.maxBindRetries,
               case .posix(let code) = error, code == .EADDRINUSE {
                bindRetries += 1
                DiagLog.log("logexport", "[\(instanceTag)] bind failed: address in use — retry \(bindRetries)/\(Self.maxBindRetries)")
                emit(.starting)
                schedulePendingBind(after: .seconds(1))
                return
            }
            DiagLog.log("logexport", "[\(instanceTag)] listener failed")
            emit(.failed("Kênh gửi log lỗi: \(error.localizedDescription)"))
        case .cancelled:
            if self.listener === listener { self.listener = nil }
            DiagLog.log("logexport", "[\(instanceTag)] listener cancelled")
        default:
            break
        }
    }

    /// Accept one connection: register it (so `stop()` can
    /// cancel it), start it on the server queue and read ONE
    /// bounded request. A client that connects and never sends
    /// is reaped by `stop()` when the screen closes.
    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                self?.handle(conn, requestData: data ?? Data())
            }
        }
    }

    /// Route on the request line's path ONLY: the exact token
    /// path gets the log and resets the failure count; anything
    /// else gets a 404 and counts. The third consecutive
    /// failure pauses the channel for 60 seconds
    /// (lockoutUntil) — the offending connection still receives
    /// its 404 before the listener goes down. While locked,
    /// every request — even one carrying the correct path —
    /// gets the same bare 404 and never the log (mirrors
    /// JoeTV: once locked, the channel serves nothing until
    /// the pause expires). An empty read (port scan, browser
    /// preconnect) is closed silently, is not an error, and
    /// never counts as a wrong attempt: a LAN scan must not be
    /// able to lock the owner out of his own export (mirrors
    /// JoeTV review F-1).
    private func handle(_ conn: NWConnection, requestData: Data) {
        guard !requestData.isEmpty else {
            conn.cancel()
            connections.removeValue(forKey: ObjectIdentifier(conn))
            return
        }
        if let until = Self.lockoutUntil, until > Date() {
            respondNotFound(to: conn)
            return
        }
        if Self.requestPath(in: requestData) == expectedPath {
            failedAttempts = 0
            respondWithLog(to: conn)
            return
        }
        failedAttempts += 1
        let locking = failedAttempts >= 3
        if locking {
            Self.lockoutUntil = Date().addingTimeInterval(60)
        }
        respondNotFound(to: conn) { [weak self] in
            guard let self, locking else { return }
            // Same gate discipline as stop(): record the
            // cancelling identity so no rebind can race this
            // teardown (§4.3.3).
            if let live = self.listener {
                let id = ObjectIdentifier(live)
                if Self.gateLiveID == id { Self.gateLiveID = nil }
                Self.gateCancellingID = id
                DiagLog.log("logexport", "[\(self.instanceTag)] listener cancelling (lockout)")
                live.cancel()
                self.listener = nil
            }
            self.wantsServing = false
            for other in self.connections.values { other.cancel() }
            self.connections.removeAll()
            self.emit(.failed("Quá 3 lần nhập sai mã — kênh gửi log đã tạm dừng 60 giây. Đóng màn hình này, chờ một chút rồi mở lại."))
        }
    }

    /// The path component of the request line
    /// ("GET /<path> HTTP/1.1"). Nothing else in the request is
    /// inspected or stored.
    nonisolated private static func requestPath(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let firstLine = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// Send the DiagLog export as a plain-text download and
    /// close. The text is taken fresh at request time, so the
    /// file includes everything logged up to the download.
    private func respondWithLog(to conn: NWConnection) {
        let body = Data(DiagLog.exportText().utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Disposition: attachment; filename=\"jtv-log.txt\"\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload)
    }

    /// Every non-matching path (and every request while the
    /// channel is locked): a bare 404, no log content, no hint
    /// about the right path. `after` runs once the answer is on
    /// its way (the lockout path uses it to take the listener
    /// down, mirroring JoeTV's respondForbidden).
    private func respondNotFound(to conn: NWConnection,
                                 after: (@MainActor () -> Void)? = nil) {
        let body = Data("404 — not found.\n".utf8)
        let header = "HTTP/1.1 404 Not Found\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload, after: after)
    }

    private func sendAndClose(_ conn: NWConnection, payload: Data,
                              after: (@MainActor () -> Void)? = nil) {
        conn.send(content: payload, completion: .contentProcessed {
            [weak self] _ in
            conn.cancel()
            Task { @MainActor in
                self?.connections.removeValue(
                    forKey: ObjectIdentifier(conn))
                after?()
            }
        })
    }

    private func emit(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
        }
    }

    // MARK: LAN address

    /// The box's first LAN IPv4 address (first up, non-loopback
    /// AF_INET address on en0/en1/en2) — copied from JoeTV's
    /// proven implementation. nil when the box has no LAN
    /// address, in which case the caller reports .failed rather
    /// than showing an address that could never answer.
    nonisolated static func lanIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = cursor {
            cursor = ptr.pointee.ifa_next
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2"
            else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr,
                              socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}

// MARK: - The screen

/// Settings → "Gửi log chẩn đoán". Owns ONE JTVLogExportServer
/// for its own lifetime only. The QR is rendered on a white
/// rounded rect on purpose (JoeTV's lesson): a QR code needs
/// its light background and quiet zone to scan — that white
/// card is a functional element, not a themed surface.
struct LogExportView: View {
    @EnvironmentObject private var session: PinSession
    @Environment(\.dismiss) private var dismiss
    @State private var server = JTVLogExportServer()
    @State private var serverState: JTVLogExportServer.State = .starting
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .center, spacing: 36) {
                Text("Gửi log chẩn đoán")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)

                switch serverState {
                case .starting:
                    ProgressView()
                        .tint(.white)
                    Text("Đang mở kênh gửi log…")
                        .font(.system(size: 29))
                        .foregroundStyle(.white)
                case .serving(let url):
                    Text(url)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !server.token.isEmpty {
                        Text("Mã trong địa chỉ: \(server.token)")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let qr = Self.qrImage(for: url) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 340, height: 340)
                            .padding(28)
                            .background(RoundedRectangle(cornerRadius: 28)
                                .fill(Color.white))
                    }
                    Text("Trên iPhone, mở Safari và nhập đúng địa chỉ trên — file log sẽ tải về máy. Hoặc dùng Camera của iPhone quét mã QR. Địa chỉ chỉ mở được khi màn hình này đang hiện và đổi mỗi lần mở. Lấy xong, gửi file vào cuộc trò chuyện.")
                        .font(.system(size: 25))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1250, alignment: .center)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 29))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1250, alignment: .center)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Đóng")
                        .font(.system(size: 28))
                }
                .focused($closeFocused)
            }
            .padding(60)
        }
        .defaultFocus($closeFocused, true)
        .onAppear {
            session.touch()
            DiagLog.log("settings", "log export screen opened")
            server.onStateChange = { state in
                serverState = state
            }
            server.start()
        }
        .onDisappear {
            server.stop()
        }
    }

    /// QR code for the serving URL (CoreImage's
    /// CIQRCodeGenerator): the filter's output is a
    /// tiny bitmap (one pixel per module), scaled up with a
    /// plain transform and rendered through a CIContext; the
    /// Image above draws it with interpolation OFF so the
    /// modules stay hard-edged and scannable.
    private static func qrImage(for string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled,
                                                  from: scaled.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
