import AppKit
import FSDriveCore
import ServiceManagement
import SwiftUI

/// The settings window: the standard macOS layout with tabs as toolbar icons. AppKit
/// hosting SwiftUI, so it opens from the menu bar item and on first launch alike (the
/// app has no Dock icon). While the window is open the app becomes a regular one, with
/// a Dock icon and a place in Cmd-Tab, so the window can be brought back from behind others.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    static let accountTab = 1
    private var window: NSWindow?

    func show(_ model: AppModel, tab: Int? = nil) {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
                let host = NSHostingController(rootView: view.environmentObject(model))
                // The window follows each tab's own size and takes its name as the title.
                host.sizingOptions = [.preferredContentSize]
                host.title = title
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            add("Загальне", "gearshape", GeneralTab())
            add("Обліковий запис", "person.crop.circle", AccountTab())
            add("Про програму", "info.circle", AboutTab())
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }
        if let tab, let tabs = window?.contentViewController as? NSTabViewController { tabs.selectedTabViewItemIndex = tab }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Back to a menu bar-only app once the window is gone.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Development aid: `FSDrive --snapshot FILE.png` draws this window into a PNG after
    /// a few seconds (enough for server discovery), without screen-recording access.
    func snapshot(to path: String) {
        // The frame view includes the title bar and toolbar tabs.
        guard let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: Account

struct AccountTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.isConnected { ConnectedAccount() } else { SignIn() }
        }
        .frame(width: 540)
    }
}

enum ServerSource: Hashable { case automatic, manual }

struct SignIn: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var browser = ServerBrowser()
    @State private var source = ServerSource.automatic
    @State private var chosen: String?
    @State private var manualAddress = ""
    @State private var user = ""
    @State private var password = ""
    @State private var device = Host.current().localizedName ?? ""

    /// "nas.lan" or "10.0.0.2" → "https://nas.lan:8740": the port and scheme are optional.
    private var serverURL: String? {
        if source == .automatic { return chosen }
        var s = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // fsdrived speaks TLS only; a bare name or IP is the NAS itself on its own port.
        if !s.contains("://") {
            s = "https://" + s
            if let u = URL(string: s), u.port == nil { s += ":8740" }
        } else if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        }
        return s
    }

    private var canSignIn: Bool {
        !model.busy && !user.isEmpty && !password.isEmpty && serverURL != nil

    }

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section {
                Picker("Спосіб", selection: $source) {
                    Text("Автоматично").tag(ServerSource.automatic)
                    Text("Вручну").tag(ServerSource.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Same height on both tabs, so the window does not jump.
                Group {
                    if source == .automatic { discovered } else { manual }
                }
                .frame(height: 132, alignment: .top)
            } header: {
                Text("Сервер FSDrive")
            }

            Section {
                TextField("Ім'я користувача", text: $user)
                SecureField("Пароль", text: $password)
                TextField("Назва цього Mac", text: $device)
            } header: {
                Text("Обліковий запис")
            } footer: {
                Text("Пароль перевіряє сервер і він не зберігається. FSDrive отримує ключ лише для цього Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }


        }
        .formStyle(.grouped)
        .scrollDisabled(true)

        HStack(spacing: 8) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button("Увійти") {
                guard let url = serverURL else { return }
                let secret = password
                password = ""
                Task { await model.connect(server: url, user: user, secret: secret, device: device) }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!canSignIn)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        }
        .onAppear { browser.search() }
        .onChange(of: browser.servers) { _, servers in
            // Pick the first server found unless the user already chose one still listed.
            if chosen == nil || !servers.contains(where: { $0.url == chosen }) { chosen = servers.first?.url }
        }
    }

    /// Servers found on the local network; there may be several.
    private var discovered: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(browser.servers) { s in
                        ServerRow(server: s, selected: chosen == s.url) { chosen = s.url }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if browser.servers.isEmpty {
                    Text(browser.searching ? "Шукаю в локальній мережі…" : "Сервер не знайдено. Спробуйте ще раз або введіть адресу вручну.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            HStack {
                Button("Знайти сервер") { browser.search() }.disabled(browser.searching)
                if browser.searching { ProgressView().controlSize(.small) }
                Spacer()
                if !browser.servers.isEmpty {
                    Text("Знайдено: \(browser.servers.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Адреса", text: $manualAddress, prompt: Text("nas.local або 10.0.0.2"))
            Text("Ім'я або IP-адреса NAS у локальній мережі. Порт 8740 додається сам; для доступу через проксі вкажіть повну адресу https://…")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One discovered server, selectable like a list row.
struct ServerRow: View {
    let server: DiscoveredServer
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2).frame(width: 28)
                    .foregroundStyle(selected ? Color.white : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.model.isEmpty ? server.name : "\(server.name) · \(server.model)")
                    Text(server.url.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ConnectedAccount: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmSignOut = false

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section("Обліковий запис") {
                LabeledContent("Сервер", value: model.host)
                LabeledContent("Користувач", value: model.userName.isEmpty ? "—" : model.userName)
                LabeledContent("Цей Mac", value: model.config?.device ?? "")
                // Shown in the same form on the FSDrive page in QTS, for comparison.
                LabeledContent("Ключ сервера", value: model.config?.serverCode ?? "буде закріплено при з'єднанні")
            }
            Section("З'єднання") {
                LabeledContent("Зараз") {
                    Label(model.routeShort, systemImage: model.routeSymbol ?? "antenna.radiowaves.left.and.right")
                }
                LabeledContent("Ззовні", value: model.externalDescription)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)

        HStack {
            Button("Відкрити у Finder") { model.openInFinder() }
            Button("Синхронізувати зараз") { model.syncNow() }
            Spacer()
            Button("Вийти з облікового запису…", role: .destructive) { confirmSignOut = true }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        }
        .confirmationDialog("Вийти з облікового запису на цьому Mac?", isPresented: $confirmSignOut) {
            Button("Вийти", role: .destructive) { Task { await model.disconnect() } }
        } message: {
            Text("FSDrive зникне з Finder. Файли на сервері не зміняться; ще не надіслані зміни macOS збереже окремо.")
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Запускати FSDrive під час входу в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            problem = nil
                        } catch {
                            problem = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("Значок у рядку меню показує стан синхронізації; розділ у Finder працює й без нього.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("FSDrive").font(.title).bold()
            Text("Версія \(FSDriveVersion.string)").foregroundStyle(.secondary)
            Text("Синхронізація файлів з вашим NAS. Файли на сервері лишаються звичайними теками.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
        }
        .frame(width: 540, height: 300)
    }
}
