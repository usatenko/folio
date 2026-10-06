import ServiceManagement
import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            SettingsView().environmentObject(PortfolioStore.shared)
        }
        // icon only: the numbers live in the widget; this is the way to Settings, Refresh and Quit
        MenuBarExtra("Folio", systemImage: "chart.line.uptrend.xyaxis") {
            MenuContent()
        }
    }
}

struct MenuContent: View {
    @ObservedObject private var store = PortfolioStore.shared

    var body: some View {
        if let p = store.portfolio {
            Text("\(Fmt.money(p.nav, p.currency))   \(Fmt.arrow(p.dayChangePct)) \(Fmt.pct(p.dayChangePct)) today")
            Text("Updated \(p.fetchedDate, style: .time)")
            Divider()
        }
        if let e = store.lastError {
            Text(e)
            Divider()
        }
        Button(store.refreshing ? "Refreshing…" : "Refresh now") { Task { await store.refresh() } }
            .disabled(store.refreshing)
        Button("Settings…") { AppDelegate.openSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Folio") { NSApplication.shared.terminate(nil) }
    }
}

/// No menu bar item and no Dock icon while idle: the app polls in the background for the widget.
/// Opening the app (Finder, Spotlight, Launchpad) shows Settings, the only window; while it is open
/// the app behaves like a regular one, with a Dock icon and menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the widget only updates while Folio runs; offer login-item registration once, never silently
        if !UserDefaults.standard.bool(forKey: "loginItemOffered"), SMAppService.mainApp.status == .notRegistered {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            let alert = NSAlert()
            alert.messageText = "Start Folio at login?"
            alert.informativeText = "The widget only updates while Folio is running. You can change this later in Settings."
            alert.addButton(withTitle: "Start at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { try? SMAppService.mainApp.register() }
        }
        PortfolioStore.shared.startPolling()
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
        // only first run needs a window; otherwise stay silent (menu bar icon and reopen lead to Settings)
        if Credentials.load() == nil {
            Self.openSettings()
        }
    }

    /// Dropping an ~/.ibkr folder (or `open -a Folio ~/.ibkr`) imports the credentials.
    func application(_ application: NSApplication, open urls: [URL]) {
        if Credentials.load() != nil {
            // never silently replace working credentials with whatever file was opened
            let alert = NSAlert()
            alert.messageText = "Replace the saved IBKR credentials?"
            alert.informativeText = "Folio already has credentials in your Keychain. Import from \(urls.first?.lastPathComponent ?? "the opened item") and replace them?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let folder = isDir ? url : url.deletingLastPathComponent()
            let env = url.lastPathComponent.hasPrefix("ibkr_env_") ? String(url.lastPathComponent.dropFirst(9)) : "live"
            do {
                let creds = try Credentials.importFolder(folder, env: env)
                try creds.save()
                Task { @MainActor in
                    PortfolioStore.shared.credentialsChanged()
                    await PortfolioStore.shared.refresh()
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        Self.openSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var connectWindow: NSWindow?
    private var connectModel: ConnectModel?

    @MainActor func openConnect() {
        if connectWindow == nil {
            let model = ConnectModel()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Connect to IBKR"
            w.contentViewController = NSHostingController(rootView: ConnectView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            connectWindow = w
            connectModel = model
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        connectWindow?.makeKeyAndOrderFront(nil)
    }

    static func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func windowClosed(_ note: Notification) {
        // back to the background once no window is left
        DispatchQueue.main.async {
            let closing = note.object as? NSWindow
            if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.canBecomeKey }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
