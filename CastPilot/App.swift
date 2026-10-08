//  App.swift
//  CastPilot
//
//  App entry point, windows, live-window level, File-menu commands and Finder opens.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App Entry Point

@main
struct MidiCastSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var midi = MidiController()
    @StateObject private var emailClient = IMAPClient()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        // Compact live window — stays on top of Nuendo
        WindowGroup("CastPilot Live", id: "live") {
            LiveView(midi: midi, emailClient: emailClient)
                .onAppear {
                    setupLiveWindow()
                    // Shows double-clicked in the Finder arrive via the app delegate.
                    appDelegate.openShow = { url in ShowActions.open(url, midi) }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 280, height: 470)
        .handlesExternalEvents(matching: [])   // opened files go to the delegate, not a new window
        .commands { ShowCommands(midi: midi) }

        // Single show-editor window — Window (not WindowGroup) ensures only one instance
        Window("CastPilot – Show bearbeiten", id: "config") {
            ConfigView(midi: midi)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 680)

        // Email import window
        Window("CastPilot – E-Mail-Import", id: "email") {
            EmailView(midi: midi, emailClient: emailClient)
        }
        .windowResizability(.contentSize)

        // App-wide settings (⌘,): MIDI output & navigation, e-mail account, updates
        Settings {
            SettingsView(midi: midi, updater: updater)
        }
    }

    private func setupLiveWindow() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if window.title == "CastPilot Live" {
                    LiveWindow.apply(to: window)   // always-on-top is optional (Settings → Allgemein)
                    window.titlebarAppearsTransparent = true
                    // The header already shows "CastPilot" + show name — don't repeat it in the title bar.
                    window.titleVisibility = .hidden
                    window.isMovableByWindowBackground = true
                }
            }
        }
    }
}

/// Keeps the live window above Nuendo and on every desktop — optional, per Mac
/// (Settings → Allgemein, Window menu). On by default.
enum LiveWindow {
    static let onTopKey = "liveWindowAlwaysOnTop"
    static var isOnTop: Bool { UserDefaults.standard.object(forKey: onTopKey) as? Bool ?? true }

    /// Re-applies the setting to open live windows (after it was toggled).
    static func applyLevel() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window.title == "CastPilot Live" {
                apply(to: window)
            }
        }
    }

    static func apply(to window: NSWindow) {
        window.level = isOnTop ? .floating : .normal
        window.collectionBehavior = isOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    /// Brings the existing live window to the front (un-minimizing it); opens one only if none exists.
    static func show(orOpen open: () -> Void) {
        guard let window = NSApplication.shared.windows.first(where: { $0.title == "CastPilot Live" }) else {
            open()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Receives .castpilot files opened from the Finder (double-click, "Öffnen mit", Dock).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the UI is up; files that arrive earlier (app launched by a double-click) wait.
    var openShow: ((URL) -> Void)? {
        didSet {
            guard let openShow else { return }
            pending.forEach(openShow)
            pending.removeAll()
        }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "castpilot" {
            if let openShow { openShow(url) } else { pending.append(url) }
        }
    }
}

// MARK: - Show document actions (File menu, Finder)

/// AppKit glue for the File menu: open/save panels, the "save changes?" prompt and error alerts.
enum ShowActions {
    static var showType: UTType { UTType(filenameExtension: "castpilot", conformingTo: .json) ?? .json }

    /// Asks to save unsaved show changes first. Returns false when the user cancels.
    static func confirmSaveIfNeeded(_ midi: MidiController) -> Bool {
        guard midi.isShowModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Änderungen an „\(midi.config.showName)“ speichern?"
        alert.informativeText = "Sonst gehen die Änderungen an Rollen, Tracks und Darstellern verloren."
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Nicht speichern")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(midi)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    static func newShow(_ midi: MidiController) {
        guard confirmSaveIfNeeded(midi) else { return }
        midi.newShow()
    }

    static func openPanel(_ midi: MidiController) {
        guard confirmSaveIfNeeded(midi) else { return }
        let panel = NSOpenPanel()
        panel.title = "Show laden"
        panel.directoryURL = midi.showsDir
        panel.allowedContentTypes = [showType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url, midi)
    }

    /// Opens a show from "Zuletzt verwendet" or the Finder.
    static func open(_ url: URL, _ midi: MidiController) {
        guard confirmSaveIfNeeded(midi) else { return }
        load(url, midi)
    }

    @discardableResult
    static func save(_ midi: MidiController) -> Bool {
        guard let url = midi.showFileURL else { return saveAs(midi) }
        return write(url, midi)
    }

    @discardableResult
    static func saveAs(_ midi: MidiController) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Show speichern unter"
        panel.nameFieldStringValue = midi.config.showName + ".castpilot"
        panel.directoryURL = midi.showFileURL?.deletingLastPathComponent() ?? midi.showsDir
        panel.allowedContentTypes = [showType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(url, midi)
    }

    static func revealInFinder(_ midi: MidiController) {
        guard let url = midi.showFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func load(_ url: URL, _ midi: MidiController) {
        do { try midi.openShow(at: url) } catch { showError("Show konnte nicht geladen werden", error) }
    }

    private static func write(_ url: URL, _ midi: MidiController) -> Bool {
        do { try midi.saveShow(to: url); return true } catch {
            showError("Show konnte nicht gespeichert werden", error)
            return false
        }
    }

    private static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// File menu: Neue Show, Show laden, Zuletzt verwendet, Show speichern (unter), Im Finder zeigen.
/// Window menu: Live-Fenster (replaces File > New Live Window).
struct ShowCommands: Commands {
    @ObservedObject var midi: MidiController
    @Environment(\.openWindow) private var openWindow
    @AppStorage(LiveWindow.onTopKey) private var liveWindowOnTop = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neue Show") { ShowActions.newShow(midi) }
                .keyboardShortcut("n")
            Button("Show laden …") { ShowActions.openPanel(midi) }
                .keyboardShortcut("o")
            Menu("Zuletzt verwendet") {
                ForEach(midi.recentShows.filter { FileManager.default.fileExists(atPath: $0.path) }, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { ShowActions.open(url, midi) }
                }
                Divider()
                Button("Liste löschen") { midi.clearRecentShows() }
                    .disabled(midi.recentShows.isEmpty)
            }
        }
        // After "new", not replacing .saveItem — that group also holds "Close" (⌘W).
        CommandGroup(after: .newItem) {
            Divider()
            Button("Show speichern") { ShowActions.save(midi) }
                .keyboardShortcut("s")
            Button("Show speichern unter …") { ShowActions.saveAs(midi) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Im Finder zeigen") { ShowActions.revealInFinder(midi) }
                .disabled(midi.showFileURL == nil)
        }
        CommandGroup(before: .windowList) {
            Button("Live-Fenster") { LiveWindow.show { openWindow(id: "live") } }
                .keyboardShortcut("l")
            Toggle("Live-Fenster immer im Vordergrund", isOn: $liveWindowOnTop)
            Divider()
        }
    }
}

