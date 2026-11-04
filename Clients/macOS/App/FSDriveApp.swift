import SwiftUI
import FSDriveCore

@main
struct FSDriveApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            // The Finder sidebar hexagon, marked with the sync state.
            Image(nsImage: model.statusIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar panel: status at a glance and the few things done often. Signing in
/// and everything else lives in the settings window.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FSDrive").font(.headline)
                    // How the NAS is reached: on the local network or through the internet.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let symbol = model.routeSymbol { Image(systemName: symbol).imageScale(.small) }
                        Text(model.statusLine).lineLimit(2)
                    }
                    .font(.caption)
                    .foregroundStyle(model.error == nil ? Color.secondary : .orange)
                }
                Spacer()
            }
            .padding(12)

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if model.isConnected {
                    MenuRow("Відкрити FSDrive у Finder", systemImage: "folder") { dismiss(); model.openInFinder() }
                    MenuRow("Синхронізувати зараз", systemImage: "arrow.triangle.2.circlepath") { dismiss(); model.syncNow() }
                } else {
                    MenuRow("Підключитися…", systemImage: "person.crop.circle.badge.plus") { dismiss(); model.openSettings(tab: SettingsWindow.accountTab) }
                }
            }
            .padding(6)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                MenuRow("Налаштування…", systemImage: "gearshape") { dismiss(); model.openSettings() }
                MenuRow("Вийти з FSDrive", systemImage: "power") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 280)
    }
}

/// A full-width row that highlights on hover, like a menu item.
struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hovering ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(hovering ? Color.white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
