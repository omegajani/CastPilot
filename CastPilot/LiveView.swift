//  LiveView.swift
//  CastPilot
//
//  The compact live window: pick today's cast, send to Nuendo.

import SwiftUI
import AppKit

// MARK: - Live View

struct LiveView: View {
    @ObservedObject var midi: MidiController
    @ObservedObject var emailClient: IMAPClient
    @ObservedObject var digico: DigicoMonitor
    @State private var fireScale: CGFloat = 1.0
    @Environment(\.openWindow) private var openWindow
    @AppStorage(LiveWindow.onTopKey) private var liveWindowOnTop = true

    private let nameW: CGFloat = 52
    /// Width of one check column at the right of the role rows ("Pult", later "Nuendo").
    private let checkColW: CGFloat = 34

    private var hasAssignment: Bool {
        midi.config.roles.contains { $0.selectedMemberId != nil }
    }

    /// Titles of the check columns shown right now, in display order.
    private var checkColumns: [String] {
        digico.isEnabled ? ["Pult"] : []
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Role rows
            ScrollView {
                VStack(spacing: 4) {
                    if !checkColumns.isEmpty { checkColumnHeader }
                    ForEach($midi.config.roles) { $role in
                        roleRow($role)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            sendArea
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
        .onChange(of: midi.config) { midi.saveConfig() }
        .onChange(of: liveWindowOnTop) { LiveWindow.applyLevel() }
        .task(id: midi.config.activeDigicoBridge) { digico.configure(address: midi.config.activeDigicoBridge) }
    }

    /// Small titles above the check columns, aligned with the badges in the role rows.
    private var checkColumnHeader: some View {
        HStack(spacing: 0) {
            Spacer()
            ForEach(checkColumns, id: \.self) { title in
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: checkColW)
            }
        }
        .padding(.horizontal, 18)   // = row padding (10) + outer padding (8)
        .padding(.bottom, -2)
    }

    /// "Ch 7: Mira Lang" or, when several channels carry the same wrong player,
    /// "Ch 1+7: Sofia Brandt".
    static func wrongChannelsText(_ loaded: [Int: String]) -> String {
        let byPlayer = Dictionary(grouping: loaded.keys.sorted(), by: { loaded[$0]! })
        return byPlayer
            .sorted { $0.value.first! < $1.value.first! }
            .map { player, chs in "Ch \(chs.map(String.init).joined(separator: "+")): \(player)" }
            .joined(separator: " · ")
    }

    /// The console check for a role; nil when DiGiCo is off or the role has no channels.
    /// Stale data never shows a green tick.
    private func digicoStatus(_ role: Role) -> DigicoStatus? {
        guard digico.isEnabled else { return nil }
        return DigicoCheck.status(of: role, allRoles: midi.config.roles,
                                  snapshot: digico.isStale ? nil : digico.snapshot)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("CastPilot")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                if !midi.config.showName.isEmpty {
                    HStack(spacing: 5) {
                        Text(midi.config.showName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if midi.needsSave {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                                .help("Show nicht gespeichert (⌘S)")
                        }
                    }
                }
            }
            Spacer()
            // Quick import: fetch + apply immediately, then open email window
            Button(action: quickImport) {
                if emailClient.isFetching {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(emailClient.isFetching)
            .help("Besetzung sofort aus E-Mail importieren")
            Button {
                openWindow(id: "config")
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show bearbeiten")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func quickImport() {
        let pw = keychainLoad(account: midi.config.emailConfig.username) ?? ""
        let keywords = midi.config.roles.map { $0.emailKeyword }
        Task {
            await emailClient.fetch(config: midi.config.emailConfig, password: pw, keywords: keywords)
            emailClient.buildPending(roles: midi.config.roles)
            emailClient.applyAssignments(to: &midi.config)
            midi.saveConfig()
            emailClient.openInSettings = false
            openWindow(id: "email")
        }
    }

    // MARK: Role rows

    @ViewBuilder
    private func roleRow(_ role: Binding<Role>) -> some View {
        let r = role.wrappedValue
        let coverSelected = r.selectedMemberId.map { id in r.covers.contains { $0.id == id } } ?? false
        let consoleStatus = digicoStatus(r)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(r.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: nameW, alignment: .leading)
                    .lineLimit(1)
                castMenu(role)
                // One fixed-width column per check, so ticks line up under their title.
                if digico.isEnabled {
                    Group {
                        if let consoleStatus { DigicoBadge(status: consoleStatus) } else { Color.clear }
                    }
                    .frame(width: checkColW)
                    .padding(.leading, -8)   // the HStack spacing already separates it
                }
            }

            // A wrong player on the console is the one thing to see at a glance.
            // Always name the channels, so a half-fixed role (TS right, HH wrong) is visible.
            if case .mismatch(_, let loaded)? = consoleStatus {
                subLine {
                    Group {
                        Image(systemName: "xmark.octagon.fill")
                        Text("Pult · " + Self.wrongChannelsText(loaded))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(.red)
                }
            }

            // Sub-label when a cover is selected: show the resolved playback source,
            // preferring the variant name ("Sofia & Ballett") if one exists.
            if coverSelected {
                if let resolved = r.resolvePlaybackSource(allRoles: midi.config.roles) {
                    let displayName = r.members.first(where: { $0.coverVariantOf == resolved.member.id })?.name
                        ?? resolved.member.name
                    subLine {
                        CoverBadge()
                        Text("via \(displayName)")
                        if resolved.ambiguous {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .help("Mehrere Darsteller abwesend — prüfen")
                        }
                    }
                } else {
                    subLine {
                        CoverBadge()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Kein freies Playback — wird übersprungen")
                    }
                }
            }
            // Sub-label when the borrowed role is cut: show which role's lines are included.
            if r.borrowedRoleIsCut(allRoles: midi.config.roles),
               let borrowedId = r.borrowsLinesFromRoleId,
               let borrowedRole = midi.config.roles.first(where: { $0.id == borrowedId }) {
                subLine { Text("⊕ \(borrowedRole.name)") }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(rowTint(selected: r.selectedMemberId != nil, cover: coverSelected)))
        .padding(.horizontal, 8)
    }

    /// Full-width cast menu. A Menu with our own label (instead of a bare Picker) keeps every row
    /// the same width, independent of the longest name in each role.
    private func castMenu(_ role: Binding<Role>) -> some View {
        let r = role.wrappedValue
        // Only "real" principals — variants are hidden from the picker.
        let principals = r.members
            .filter { $0.coverVariantOf == nil }
            .sorted { $0.versionPosition < $1.versionPosition }
        let title: String = {
            guard let id = r.selectedMemberId else { return "—" }
            return r.members.first(where: { $0.id == id })?.name
                ?? r.covers.first(where: { $0.id == id })?.name
                ?? "—"
        }()
        return Menu {
            Picker("", selection: role.selectedMemberId) {
                Text("—").tag(UUID?.none)
                ForEach(principals) { member in
                    Text(member.name).tag(UUID?.some(member.id))
                }
                if !r.covers.isEmpty {
                    Section("Cover") {
                        ForEach(r.covers) { cover in
                            Text(cover.name).tag(UUID?.some(cover.id))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(r.selectedMemberId == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    private func subLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.leading, nameW + 8)
    }

    private func rowTint(selected: Bool, cover: Bool) -> Color {
        if cover { return UI.coverTint.opacity(0.14) }
        return selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07)
    }

    // MARK: Send

    private var sendArea: some View {
        VStack(spacing: 6) {
            Button(action: send) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 14, weight: .semibold))
                    Text("An Nuendo senden")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.accentColor)
                .cornerRadius(8)
                .opacity(hasAssignment ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .scaleEffect(fireScale)
            .disabled(!hasAssignment)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Besetzung an Nuendo senden (⌘↩)")

            sendStatusLine
            digicoStatusLine
        }
        .padding(10)
    }

    /// Summary of the console check under the send status. Hidden while DiGiCo is off.
    @ViewBuilder
    private var digicoStatusLine: some View {
        if digico.isEnabled {
            let statuses = midi.config.roles.compactMap(digicoStatus)
            let checked = statuses.filter { if case .skipped = $0 { return false } else { return true } }
            let ok = checked.filter { if case .ok = $0 { return true } else { return false } }.count
            let wrong = checked.filter { if case .mismatch = $0 { return true } else { return false } }.count
            let time = (digico.snapshot?.readDate ?? digico.lastSuccess)?
                .formatted(date: .omitted, time: .shortened) ?? ""
            if digico.isStale {
                statusText(digico.lastError ?? "Warte auf Pultdaten …",
                           icon: "antenna.radiowaves.left.and.right.slash", tint: .orange)
            } else if checked.isEmpty {
                statusText("Pult \(time) · keine Rolle zu prüfen", icon: "minus.circle")
            } else if wrong > 0 {
                statusText("Pult \(time) · \(wrong) \(wrong == 1 ? "Rolle" : "Rollen") falsch geladen",
                           icon: "xmark.octagon.fill", tint: .red)
            } else if ok == checked.count {
                statusText("Pult \(time) · \(ok)/\(checked.count) Rollen richtig",
                           icon: "checkmark.circle.fill", tint: .green)
            } else {
                statusText("Pult \(time) · \(ok)/\(checked.count) geprüft, Rest unklar",
                           icon: "questionmark.circle", tint: .orange)
            }
        }
    }

    private func send() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { fireScale = 0.95 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { fireScale = 1.0 }
        }
        midi.fireMidi()
    }

    @ViewBuilder
    private var sendStatusLine: some View {
        switch midi.sendStatus {
        case .idle:
            statusText(hasAssignment ? "Bereit · ⌘↩" : "Noch keine Rolle besetzt")
        case .sending(let count):
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                statusText("Sende \(count) MIDI-Befehle …")
            }
        case .sent(let date, let roles, let total, let selection):
            // A stale "sent" is dangerous during a show — flag any change to the cast since.
            if selection == midi.config.roles.map(\.selectedMemberId) {
                statusText("Gesendet \(date.formatted(date: .omitted, time: .shortened)) · \(roles)/\(total) Rollen",
                           icon: "checkmark.circle.fill", tint: .green)
            } else {
                statusText("Besetzung geändert — noch nicht gesendet",
                           icon: "exclamationmark.circle.fill", tint: .orange)
            }
        case .nothingToSend:
            statusText("Nichts gesendet — keine passenden Slots",
                       icon: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func statusText(_ text: String, icon: String? = nil, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).foregroundColor(tint) }
            Text(text).foregroundColor(.secondary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

