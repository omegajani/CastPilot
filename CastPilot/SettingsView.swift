//  SettingsView.swift
//  CastPilot
//
//  Settings window (⌘,): general, MIDI, e-mail account, updates.

import SwiftUI
import AppKit

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @ObservedObject var midi: MidiController
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            MidiSettingsTab(midi: midi)
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
            EmailSettingsTab(midi: midi)
                .tabItem { Label("E-Mail", systemImage: "envelope") }
            UpdateSettingsTab(updater: updater)
                .tabItem { Label("Update", systemImage: "arrow.down.circle") }
        }
        .frame(width: 620)
        .onChange(of: midi.config) { midi.saveConfig() }
    }
}

struct GeneralSettingsTab: View {
    @AppStorage(LiveWindow.onTopKey) private var liveWindowOnTop = true

    var body: some View {
        Form {
            Section("Live-Fenster") {
                Toggle("Immer im Vordergrund", isOn: $liveWindowOnTop)
                Text("Das Live-Fenster bleibt über Nuendo und erscheint auf allen Schreibtischen. Gilt nur für diesen Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct MidiSettingsTab: View {
    @ObservedObject var midi: MidiController

    var body: some View {
        Form {
            Section("Ausgang") {
                HStack {
                    Picker("MIDI-Ausgang", selection: $midi.config.midiOutputName) {
                        Text("Virtuelle Quelle (CastPilot Source)").tag("")
                        ForEach(midi.availableDestinations) { dest in
                            Text(dest.name).tag(dest.name)
                        }
                    }
                    Button { midi.refreshDestinations() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("MIDI-Geräte neu einlesen")
                }
            }

            Section("Timing") {
                msField("Verzögerung", value: $midi.config.delayMs,
                        help: "Pause zwischen einzelnen MIDI-Befehlen")
                msField("Pause zwischen Rollen", value: $midi.config.interRoleDelayMs,
                        help: "Zusätzliche Pause zwischen den Befehlsblöcken verschiedener Rollen, damit Nuendo bei vielen Rollen nicht überlastet wird.")
            }

            Section("Nuendo-Navigation") {
                LabeledContent("Vorherige Track-Version") {
                    MidiCommandRow(cmd: $midi.config.prevVersionCommand)
                }
                LabeledContent("Nächste Track-Version") {
                    MidiCommandRow(cmd: $midi.config.nextVersionCommand)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func msField(_ label: String, value: Binding<Int>, help: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", value: value, formatter: UI.integer)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text("ms").foregroundColor(.secondary)
            }
        }
        .help(help)
    }
}

struct EmailSettingsTab: View {
    @ObservedObject var midi: MidiController
    @State private var password = ""
    @State private var savedConfirmed = false

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $midi.config.emailConfig.imapServer, prompt: Text("imap.gmx.de"))
                TextField("Port", value: $midi.config.emailConfig.imapPort, formatter: UI.integer, prompt: Text("993"))
                TextField("Benutzername", text: $midi.config.emailConfig.username, prompt: Text("name@gmx.de"))
                SecureField("Passwort", text: $password)
            } header: {
                Text("IMAP-Konto")
            } footer: {
                Text("Das Passwort liegt im macOS-Schlüsselbund.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    keychainSave(account: midi.config.emailConfig.username, secret: password)
                    midi.saveConfig()
                    savedConfirmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedConfirmed = false }
                } label: {
                    Label(savedConfirmed ? "Gesichert" : "Sichern",
                          systemImage: savedConfirmed ? "checkmark" : "key")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .onAppear { password = keychainLoad(account: midi.config.emailConfig.username) ?? "" }
    }
}

struct UpdateSettingsTab: View {
    @ObservedObject var updater: UpdateChecker
    @State private var copyConfirmed = false
    @State private var showInstallConfirm = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Installierte Version") {
                    Text(updater.currentVersion)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await updater.check() }
                    } label: {
                        if updater.isChecking {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        } else {
                            Text("Auf Update prüfen")
                        }
                    }
                    .disabled(updater.isChecking)
                }

                if let err = updater.lastError {
                    Text(err).font(.caption).foregroundColor(.red)
                } else if let latest = updater.latestVersion {
                    if updater.updateAvailable {
                        Label("Version \(latest) verfügbar", systemImage: "arrow.up.circle.fill")
                            .foregroundColor(.accentColor)

                        if updater.isInstalling {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                                Text("Lade herunter und installiere …")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        } else {
                            HStack {
                                Button("Auf GitHub öffnen") {
                                    NSWorkspace.shared.open(updater.releasePageURL)
                                }
                                .buttonStyle(.borderless)
                                Spacer()
                                Button {
                                    showInstallConfirm = true
                                } label: {
                                    Label("Jetzt aktualisieren", systemImage: "arrow.down.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .confirmationDialog("Version \(latest) installieren?",
                                                    isPresented: $showInstallConfirm) {
                                    Button("Installieren und neu starten") {
                                        Task { await updater.downloadAndInstall() }
                                    }
                                    Button("Abbrechen", role: .cancel) { }
                                } message: {
                                    Text("CastPilot lädt die neue Version herunter, ersetzt sich selbst und startet neu. Die Konfiguration bleibt erhalten.")
                                }
                            }
                        }

                        // Fallback: if the in-app install failed, surface the error and
                        // the old copy-to-Terminal command as a manual escape hatch.
                        if let ierr = updater.installError {
                            Text("Automatisches Update fehlgeschlagen: \(ierr)")
                                .font(.caption).foregroundColor(.red)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(UpdateChecker.updateCommand, forType: .string)
                                copyConfirmed = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyConfirmed = false }
                            } label: {
                                Label(copyConfirmed ? "Kopiert" : "Terminal-Befehl kopieren (Fallback)",
                                      systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
                            }
                        }
                    } else {
                        Text("Du hast die neueste Version.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

