import AppKit
import FileProvider
import Foundation
import FSDriveClientKit
import FSDriveCore

@MainActor
final class AppModel: ObservableObject {
    @Published var config = AccountConfig.load() {
        didSet { cachedAPI = nil }
    }
    /// "удома" (direct to the NAS) or "через інтернет" (through the proxy).
    @Published var route = ""
    /// One client for the session, so it remembers which address works.
    private var cachedAPI: APIClient?
    private var api: APIClient? {
        if cachedAPI == nil { cachedAPI = config?.api }
        return cachedAPI
    }
    @Published var libraries: [LibraryDTO] = []
    @Published var error: String?
    @Published var busy = false
    @Published var transfers = ""
    /// False while the last poll could not reach the server by any route.
    @Published var reachable = true

    var statusIcon: StatusIcon {
        if !isConnected { return .signedOut }
        if !reachable { return .offline }
        if error != nil { return .error }
        return transfers.isEmpty ? .synced : .syncing
    }

    private var lastSeqs: [Int64: Int64] = [:]
    private var lastAddressCheck = Date.distantPast
    private var timer: Timer?
    /// The Finder location in use; it may sit on another disk with an id macOS chose.
    private var domain: NSFileProviderDomain?
    private var manager: NSFileProviderManager? { domain.flatMap { NSFileProviderManager(for: $0) } }

    var isConnected: Bool { config != nil }
    var host: String { config?.displayHost ?? "" }
    var userName: String { config?.user ?? "" }

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--login"), i + 3 < args.count {
            // Headless setup for scripts: FSDrive --login URL TOKEN DEVICE
            Task { await connect(server: args[i + 1], user: nil, secret: args[i + 2], device: args[i + 3], openFinder: false) }
        } else if args.contains("--logout") {
            // Headless sign-out for scripts: removes the Finder location and the token.
            Task {
                await disconnect()
                NSApp.terminate(nil)
            }
        } else if config != nil {
            Task { await ensureDomain() }
            startPolling()
        } else {
            // First launch or signed out: go straight to the sign-in form.
            DispatchQueue.main.async { self.openSettings(tab: SettingsWindow.accountTab) }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            // --tab N picks the settings tab to draw (0: general, 1: account).
            let tab = args.firstIndex(of: "--tab").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                SettingsWindow.shared.show(self, tab: tab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SettingsWindow.shared.snapshot(to: path) }
            }
        }
    }

    func openSettings(tab: Int? = nil) { SettingsWindow.shared.show(self, tab: tab) }

    /// One line for the menu bar panel.
    var statusLine: String {
        if let error { return error }
        guard isConnected else { return "Не підключено" }
        let way = routeShort
        return transfers.isEmpty ? way : "\(way) · \(transfers)"
    }

    /// How the server is reached right now, for the menu bar panel.
    var routeShort: String {
        switch route {
        case "удома": return "Локально"
        case "через інтернет": return "Інтернет"
        default: return "Перевіряю з'єднання…"
        }
    }

    /// Icon for `routeShort`; nil while signed out or on an error.
    var routeSymbol: String? {
        guard isConnected, error == nil else { return nil }
        switch route {
        case "удома": return "house.fill"
        case "через інтернет": return "globe"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    var externalDescription: String {
        if let e = config?.external { return "SSH через \(e.host):\(e.port), ключ цього Mac" }
        if let url = config?.endpoints?.compactMap(URL.init(string:)).first(where: { !$0.isHomeAddress }) {
            return url.isProxyAddress ? "HTTPS: \(url.absoluteString)" : "Напряму: \(url.absoluteString)"
        }
        return "вимкнено"
    }

    /// Signs in with a server account name and password (the password is sent once and not
    /// kept), or with a ready token when `user` is nil.
    func connect(server: String, user: String?, secret: String, device: String, openFinder: Bool = true) async {
        busy = true
        defer { busy = false }
        let deviceName = device.isEmpty ? (Host.current().localizedName ?? "Mac") : device
        var candidate = AccountConfig(server: server.trimmingCharacters(in: .whitespaces), token: user == nil ? secret : "",
                                      device: deviceName, user: user)
        guard let api = candidate.api else {
            error = "Неправильна адреса сервера"
            return
        }
        do {
            _ = try await api.ping()
            // The key the server showed now is the only one accepted from here on.
            candidate.serverPin = api.trust.pin
            if let user {
                let response = try await api.login(user: user.trimmingCharacters(in: .whitespaces), password: secret, device: deviceName)
                candidate.token = response.token
                if let access = response.external { candidate.external = try AccountConfig.storeSSHKey(access) }
            }
            // Learn both addresses (home network and internet) to switch between them.
            candidate.endpoints = ServerAddresses.ordered(entered: candidate.server, info: try? await api.info())
            guard let authed = candidate.api, try await !authed.libraries().isEmpty else {
                self.error = "Для цього облікового запису немає бібліотеки"
                return
            }
            // A different server or account must not inherit the old Finder location:
            // drop it (keeping edits not yet uploaded) and start a fresh one.
            if let old = config, old.server != candidate.server || old.user != candidate.user {
                await removeDomain()
            }
            try candidate.save()
            config = candidate
            error = nil
            await ensureDomain()
            startPolling()
            if openFinder { openInFinder() }
        } catch let e as APIError {
            self.error = e.message.isEmpty ? "Помилка сервера \(e.status)" : e.message
        } catch let e as URLError where e.code == .cancelled || e.code == .secureConnectionFailed || e.code == .serverCertificateUntrusted {
            self.error = "Сервер не підтвердив свою справжність (TLS): \(e.localizedDescription)"
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .cannotConnectToHost {
            self.error = "Немає з'єднання з сервером. Перевірте адресу і дозвольте FSDrive доступ до локальної мережі: "
                + "Системні параметри → Конфіденційність і безпека → Локальна мережа."
        } catch {
            self.error = "Не вдалося підключитися: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        timer?.invalidate()
        timer = nil
        // The token stops working on the server too, not only on this Mac. Offline the
        // server forgets it after the inactivity limit.
        if let api { try? await api.signOut() }
        await removeDomain()
        AccountConfig.remove()
        SSHTunnel.remove(in: Shared.sshDir)
        config = nil
        libraries = []
        lastSeqs = [:]
    }

    /// Removes the Finder location; files with unsent changes are kept by macOS.
    private func removeDomain() async {
        let existing = (try? await NSFileProviderManager.domains()) ?? [Shared.domain]
        for d in existing {
            do {
                _ = try await NSFileProviderManager.remove(d, mode: .preserveDirtyUserData)
            } catch {
                logLine("remove domain: \(error)")
            }
        }
        domain = nil
    }

    /// Reuses the Finder location macOS already has, or creates it.
    private func ensureDomain() async {
        do {
            if let existing = try await NSFileProviderManager.domains().first {
                domain = existing
                // Re-adding refreshes the name on the startup disk; others keep theirs.
                if existing.identifier == Shared.domainIdentifier { try await NSFileProviderManager.add(Shared.domain) }
            } else {
                let fresh = Shared.domain
                try await NSFileProviderManager.add(fresh)
                domain = fresh
            }
        } catch {
            self.error = "File Provider: \(error.localizedDescription)"
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        Task { await poll() }
    }

    /// Asks the server what changed and nudges macOS to re-enumerate when anything did.
    func poll() async {
        updateTransfers()
        guard let api else { return }
        do {
            let libs = try await api.libraries()
            libraries = libs
            route = api.isDirect ? "удома" : "через інтернет"
            let seqs = Dictionary(uniqueKeysWithValues: libs.map { ($0.id, $0.latestSeq) })
            if seqs != lastSeqs {
                lastSeqs = seqs
                try await manager?.signalEnumerator(for: .workingSet)
            }
            error = nil
            reachable = true
            await refreshAddresses(api)
        } catch {
            reachable = false
            if let other = api.trust.mismatch {
                // Not a network problem: someone else answers, or the NAS got a new key.
                self.error = "Ключ сервера змінився (\(ServerPin.code(other))). З'єднання заблоковано; "
                    + "якщо ключ на NAS справді новий, вийдіть і увійдіть знову."
            } else {
                self.error = "Сервер недоступний"
            }
        }
    }

    /// The server announces its own addresses; if the router gave the NAS a new IP or
    /// the admin set an internet address, keep the saved list in step (once a minute).
    private func refreshAddresses(_ api: APIClient) async {
        guard Date().timeIntervalSince(lastAddressCheck) > 60, var current = config,
              let info = try? await api.info() else { return }
        lastAddressCheck = Date()
        var changed = false
        let fresh = ServerAddresses.ordered(entered: current.server, info: info)
        if fresh != current.endpoints {
            current.endpoints = fresh
            changed = true
        }
        // External connection switched on while this Mac was already signed in: take a
        // key now, while at home. Switched off: forget the key.
        if info.external == true, current.external == nil, api.isDirect,
           let access = try? await api.externalAccess(), let kept = try? AccountConfig.storeSSHKey(access) {
            current.external = kept
            changed = true
        } else if info.external != true, current.external != nil, api.isDirect {
            SSHTunnel.remove(in: Shared.sshDir)
            Keychain.remove(.sshKey)
            current.external = nil
            changed = true
        }
        guard changed else { return }
        try? current.save()
        config = current  // the next request uses a client built from the new list
    }

    func syncNow() {
        lastSeqs = [:]
        Task { await poll() }
    }

    private func updateTransfers() {
        guard let manager else { return }
        let up = manager.globalProgress(for: .uploading)
        let down = manager.globalProgress(for: .downloading)
        var parts = [String]()
        if !down.isFinished, down.totalUnitCount > 0 { parts.append("↓ \(Int(down.fractionCompleted * 100))%") }
        if !up.isFinished, up.totalUnitCount > 0 { parts.append("↑ \(Int(up.fractionCompleted * 100))%") }
        transfers = parts.joined(separator: "  ")
    }

    func openInFinder(library: LibraryDTO? = nil) {
        guard let manager else { return }
        let id = library.map { ItemID.library($0.id).identifier } ?? .rootContainer
        Task {
            do {
                // The URL is security-scoped: the sandbox lets the app hand it to
                // Finder only while access is claimed.
                let url = try await manager.getUserVisibleURL(for: id)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                NSWorkspace.shared.open(url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
