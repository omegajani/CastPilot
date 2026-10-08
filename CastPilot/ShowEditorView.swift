//  ShowEditorView.swift
//  CastPilot
//
//  The show editor: roles, tracks, cast, covers and the MIDI preview.

import SwiftUI
import AppKit

// MARK: - Show Editor

struct ConfigView: View {
    @ObservedObject var midi: MidiController
    @State private var selectedRoleId: UUID? = nil
    @State private var roleToDelete: UUID? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            if let idx = midi.config.roles.firstIndex(where: { $0.id == selectedRoleId }) {
                RoleDetailView(role: $midi.config.roles[idx], allRoles: midi.config.roles)
                    .id(selectedRoleId)   // fresh list selections per role
            } else {
                ContentUnavailableView("Keine Rolle ausgewählt",
                                       systemImage: "person.2",
                                       description: Text("Wähle links eine Rolle aus."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Einstellungen", systemImage: "gearshape")
                }
                .help("Einstellungen öffnen (⌘,)")
            }
        }
        .frame(minWidth: 1080, minHeight: 580)
        .navigationTitle(midi.config.showName)
        .navigationSubtitle(midi.showFileURL == nil ? "Noch nicht gespeichert" : (midi.isShowModified ? "Nicht gespeichert" : ""))
        .onAppear {
            if selectedRoleId == nil { selectedRoleId = midi.config.roles.first?.id }
        }
        .onChange(of: midi.config) { midi.saveConfig() }
        .confirmationDialog("Rolle löschen?",
                            isPresented: Binding(get: { roleToDelete != nil },
                                                 set: { if !$0 { roleToDelete = nil } }),
                            presenting: roleToDelete) { id in
            Button("Löschen", role: .destructive) { deleteRole(id) }
            Button("Abbrechen", role: .cancel) { }
        } message: { id in
            let name = midi.config.roles.first(where: { $0.id == id })?.name ?? ""
            Text("„\(name)“ wird mit allen Tracks, Darstellern und Covers entfernt.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            showSection

            Divider()

            SectionHeader(title: "Rollen")
            List(selection: $selectedRoleId) {
                ForEach(midi.config.roles) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.name.isEmpty ? "Unbenannte Rolle" : role.name)
                            .font(UI.itemTitle)
                            .foregroundColor(.primary)
                        Text(role.emailKeyword.isEmpty ? "Kein Stichwort" : role.emailKeyword)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(role.id)
                    .contextMenu {
                        Button("Rolle löschen …", role: .destructive) { roleToDelete = role.id }
                    }
                }
                .onDelete { offsets in
                    roleToDelete = offsets.first.map { midi.config.roles[$0].id }
                }
            }
            .listStyle(.sidebar)

            Divider()
            AddRemoveBar(addHelp: "Rolle hinzufügen",
                         removeHelp: "Ausgewählte Rolle löschen",
                         canRemove: selectedRoleId != nil,
                         onAdd: addRole,
                         onRemove: { roleToDelete = selectedRoleId })
        }
    }

    // Show section — the open show file. Opening and saving live in the File menu.
    private var showSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Show")
                .font(.headline)
            Text(midi.config.showName)
                .font(UI.itemTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                if midi.needsSave {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
                Text(showStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(midi.showFileURL?.path ?? "Mit ⌘S als Datei speichern")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UI.pad)
    }

    private var showStatus: String {
        guard let url = midi.showFileURL else { return "Noch nicht gespeichert · ⌘S" }
        return midi.isShowModified ? "Nicht gespeichert · ⌘S" : "Gespeichert · \(url.lastPathComponent)"
    }

    private func addRole() {
        let r = Role()
        midi.config.roles.append(r)
        selectedRoleId = r.id
    }

    private func deleteRole(_ id: UUID) {
        if selectedRoleId == id { selectedRoleId = nil }
        midi.config.roles.removeAll { $0.id == id }
    }
}

// MARK: - Role Detail View

struct RoleDetailView: View {
    @Binding var role: Role
    var allRoles: [Role] = []
    @State private var selectedTrackId: UUID? = nil
    @State private var selectedMemberId: UUID? = nil
    @State private var selectedCoverId: UUID? = nil

    private let trackW: CGFloat = 480
    private let memberMinW: CGFloat = 280

    private var sortedMembers: [CastMember] {
        role.members.sorted { $0.versionPosition < $1.versionPosition }
    }

    /// Real principals only — variants are never a playback source or link target.
    private var principals: [CastMember] {
        sortedMembers.filter { $0.coverVariantOf == nil }
    }

    private func nextFreePosition() -> Int {
        let used = Set(role.members.map { $0.versionPosition })
        var pos = 1
        while used.contains(pos) { pos += 1 }
        return pos
    }

    /// Id-based binding, so a row never writes into the wrong member after the array changed.
    private func memberBinding(_ id: UUID) -> Binding<CastMember> {
        Binding(
            get: { role.members.first(where: { $0.id == id }) ?? CastMember(id: id) },
            set: { newValue in
                if let i = role.members.firstIndex(where: { $0.id == id }) { role.members[i] = newValue }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            roleHeader

            Divider()

            HStack(spacing: 0) {
                tracksColumn
                    .frame(width: trackW)
                    .frame(maxHeight: .infinity)

                Divider()

                peopleColumn
                    .frame(minWidth: memberMinW, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Role header

    private var roleHeader: some View {
        HStack(spacing: 20) {
            TextField("Rollenname", text: $role.name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .frame(minWidth: 120, maxWidth: 220)

            FieldRow("Stichwort", labelWidth: nil) {
                TextField("z. B. AURORA", text: $role.emailKeyword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            .help("Rollenname, wie er in der Besetzungs-E-Mail steht")

            // When the linked role is "cut", this role uses the Ballett variants (combined playback).
            FieldRow("Singt auch für", labelWidth: nil) {
                Picker("", selection: Binding<String>(
                    get: { role.borrowsLinesFromRoleId?.uuidString ?? "" },
                    set: { newValue in
                        role.borrowsLinesFromRoleId = newValue.isEmpty ? nil : UUID(uuidString: newValue)
                    }
                )) {
                    Text("—").tag("")
                    ForEach(allRoles.filter { $0.id != role.id }) { r in
                        Text(r.name).tag(r.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(width: 150, alignment: .leading)
            }
            .help("Ist die gewählte Rolle heute „cut“, nutzt diese Rolle die Ballett-Varianten mit dem kombinierten Playback.")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, UI.pad)
        .padding(.vertical, 10)
    }

    // MARK: Tracks

    private var tracksColumn: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Tracks")

            List(selection: $selectedTrackId) {
                ForEach($role.tracks) { $track in
                    trackCard($track)
                        .tag(track.id)
                        .contextMenu {
                            Button("Track löschen", role: .destructive) { removeTrack(track.id) }
                        }
                }
                .onDelete { role.tracks.remove(atOffsets: $0) }
            }

            Divider()
            AddRemoveBar(addHelp: "Track hinzufügen",
                         removeHelp: "Ausgewählten Track löschen",
                         canRemove: selectedTrackId != nil,
                         onAdd: addTrack,
                         onRemove: { if let id = selectedTrackId { removeTrack(id) } })
        }
    }

    private func trackCard(_ track: Binding<NuendoTrack>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Track-Name", text: track.name)
                .font(UI.itemTitle)

            FieldRow("Slots") {
                Stepper(value: Binding(
                    get: { track.wrappedValue.versionCount },
                    set: { newValue in
                        var t = track.wrappedValue
                        t.versionCount = newValue
                        t.syncSlotAssignmentsToVersionCount()
                        track.wrappedValue = t
                    }
                ), in: 1...32) {
                    Text("\(track.wrappedValue.versionCount)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 18, alignment: .leading)
                }
                .fixedSize()
                .help("Anzahl der Track-Versionen in Nuendo")
            }

            FieldRow("Auswahl-Befehl") {
                MidiCommandRow(cmd: track.selectCommand)
            }

            ForEach(1...max(1, track.wrappedValue.versionCount), id: \.self) { slot in
                slotAssignmentRow(track: track, slot: slot)
            }
        }
        .padding(.vertical, 6)
    }

    /// One row per slot in a track: "Slot N  [member dropdown]".
    /// Picking a member moves them to this slot and clears them from any other slot in this track.
    private func slotAssignmentRow(track: Binding<NuendoTrack>, slot: Int) -> some View {
        let idx = slot - 1
        let currentId: String? = (idx < track.wrappedValue.slotAssignments.count) ? track.wrappedValue.slotAssignments[idx] : nil
        return FieldRow("Slot \(slot)") {
            Picker("", selection: Binding<String>(
                get: { currentId ?? "" },
                set: { newValue in
                    let memberUUID: UUID? = newValue.isEmpty ? nil : UUID(uuidString: newValue)
                    track.wrappedValue.setMember(memberUUID, atSlot: slot)
                }
            )) {
                Text("—").tag("")
                ForEach(sortedMembers) { member in
                    Text(memberDisplayName(member)).tag(member.id.uuidString)
                }
            }
            .labelsHidden()
            .frame(width: 200, alignment: .leading)
        }
    }

    private func addTrack() {
        let t = NuendoTrack(name: "Neuer Track")
        role.tracks.append(t)
        selectedTrackId = t.id
    }

    private func removeTrack(_ id: UUID) {
        if selectedTrackId == id { selectedTrackId = nil }
        role.tracks.removeAll { $0.id == id }
    }

    // MARK: Members & covers

    private var peopleColumn: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Darsteller")

            List(selection: $selectedMemberId) {
                ForEach(sortedMembers) { member in
                    memberRow(member)
                        .tag(member.id)
                        .contextMenu {
                            Button("Darsteller löschen", role: .destructive) { removeMember(member.id) }
                        }
                }
                .onMove(perform: moveMembers)
                .onDelete { offsets in
                    let ids = offsets.map { sortedMembers[$0].id }
                    role.members.removeAll { ids.contains($0.id) }
                }
            }

            Divider()
            AddRemoveBar(addHelp: "Darsteller hinzufügen",
                         removeHelp: "Ausgewählten Darsteller löschen",
                         canRemove: selectedMemberId != nil,
                         onAdd: addMember,
                         onRemove: { if let id = selectedMemberId { removeMember(id) } })

            Divider()

            SectionHeader(title: "Cover")

            List(selection: $selectedCoverId) {
                ForEach($role.covers) { $cover in
                    coverRow($cover)
                        .tag(cover.id)
                        .contextMenu {
                            Button("Cover löschen", role: .destructive) { removeCover(cover.id) }
                        }
                }
                .onDelete { role.covers.remove(atOffsets: $0) }
            }

            Divider()
            AddRemoveBar(addHelp: "Cover hinzufügen",
                         removeHelp: "Ausgewähltes Cover löschen",
                         canRemove: selectedCoverId != nil,
                         onAdd: addCover,
                         onRemove: { if let id = selectedCoverId { removeCover(id) } })

            if let member = role.members.first(where: { $0.id == selectedMemberId }) {
                Divider()
                MidiSequencePreview(role: role, member: member)
            }
        }
    }

    private func memberRow(_ member: CastMember) -> some View {
        let isVariant = member.coverVariantOf != nil
        let parentName = role.members.first(where: { $0.id == member.coverVariantOf })?.name ?? "?"
        let linkTargets = principals.filter { $0.id != member.id }
        return VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: memberBinding(member.id).name)
                .font(UI.itemTitle)
                .italic(isVariant)
            // Variant link, displayed as a clickable caption opening a menu.
            // - For principals (no link): "Als Ballett-Variante markieren"
            // - For variants: "↪ Variante von <Name>" — click to change/remove
            Menu {
                Button("— (keine Variante)") {
                    memberBinding(member.id).wrappedValue.coverVariantOf = nil
                }
                if !linkTargets.isEmpty {
                    Divider()
                    ForEach(linkTargets) { p in
                        Button(p.name) {
                            memberBinding(member.id).wrappedValue.coverVariantOf = p.id
                        }
                    }
                }
            } label: {
                Text(isVariant ? "↪ Variante von \(parentName)" : "Als Ballett-Variante markieren")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func coverRow(_ cover: Binding<Cover>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Name", text: cover.name)
                .font(UI.itemTitle)
            FieldRow("Playback") {
                Picker("", selection: Binding<String>(
                    get: { cover.wrappedValue.fixedSourceMemberId?.uuidString ?? "" },
                    set: { newValue in
                        cover.wrappedValue.fixedSourceMemberId = newValue.isEmpty ? nil : UUID(uuidString: newValue)
                    }
                )) {
                    Text("Auto (dynamisch)").tag("")
                    ForEach(principals) { m in
                        Text(m.name).tag(m.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    /// Drag-reorder: renumber versionPosition 1…n in the new order. It drives the live-picker order
    /// and the priority of dynamic covers; slot assignments are UUID-based and stay untouched.
    private func moveMembers(from source: IndexSet, to destination: Int) {
        var ids = sortedMembers.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        var members = role.members
        for (pos, id) in ids.enumerated() {
            if let i = members.firstIndex(where: { $0.id == id }) { members[i].versionPosition = pos + 1 }
        }
        role.members = members
    }

    private func addMember() {
        var r = role
        var m = CastMember()
        m.versionPosition = nextFreePosition()
        r.members.append(m)
        // Auto-raise versionCount on all tracks to cover the new member count.
        // Must also sync slotAssignments — otherwise the array stays shorter than
        // versionCount and the slot picker crashes with "Index out of range".
        let count = r.members.count
        for i in r.tracks.indices where r.tracks[i].versionCount < count {
            r.tracks[i].versionCount = count
            r.tracks[i].syncSlotAssignmentsToVersionCount()
        }
        role = r
        selectedMemberId = m.id
    }

    private func removeMember(_ id: UUID) {
        if selectedMemberId == id { selectedMemberId = nil }
        role.members.removeAll { $0.id == id }
    }

    private func addCover() {
        let c = Cover(name: "Neues Cover")
        role.covers.append(c)
        selectedCoverId = c.id
    }

    private func removeCover(_ id: UUID) {
        if selectedCoverId == id { selectedCoverId = nil }
        role.covers.removeAll { $0.id == id }
    }
}

// MARK: - MIDI Sequence Preview

struct MidiSequencePreview: View {
    let role: Role
    let member: CastMember

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vorschau MIDI-Sequenz für \(member.name)")
                .font(.caption).bold().foregroundColor(.secondary)
                .padding(.horizontal, UI.pad)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, UI.pad)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 130)
        }
        .background(Color.secondary.opacity(0.06))
    }

    private func lines() -> [String] {
        var out: [String] = []
        // Mirror fireMidi: for a Principal preview, prefer the principal's own slot,
        // fall back to the variant slot (e.g. for "Lena" with only "Lena & Ballett" tracks).
        let variant = role.members.first(where: { $0.coverVariantOf == member.id })
        for track in role.tracks {
            let principalSlot = track.slot(of: member.id)
            let variantSlot   = variant.flatMap { track.slot(of: $0.id) }
            guard let targetSlot = principalSlot ?? variantSlot else {
                out.append("[\(track.name)] — nicht zugewiesen, übersprungen")
                continue
            }
            let usedVariant = (principalSlot == nil) && variantSlot != nil
            let suffix = usedVariant ? "  (→ \(variant?.name ?? "Variante"))" : ""
            out.append("[\(track.name)] → \(cmdStr(track.selectCommand))")
            let r = max(0, track.versionCount - 1)
            if r > 0 { out.append("  ↑ Prev ×\(r)  (auf Anfang)") }
            let f = max(0, targetSlot - 1)
            if f > 0 { out.append("  ↓ Next ×\(f)  → Slot \(targetSlot)\(suffix)") }
            else      { out.append("  → Slot 1 (erste Version)\(suffix)") }
        }
        return out
    }

    private func cmdStr(_ cmd: MidiCommand) -> String {
        switch cmd.type {
        case .pc:   return "PC\(cmd.value1) CH\(cmd.channel)"
        case .cc:   return "CC\(cmd.value1) val=\(cmd.value2) CH\(cmd.channel)"
        case .note: return "Note\(cmd.value1) vel=\(cmd.value2) CH\(cmd.channel)"
        }
    }
}

// MARK: - MIDI Command Row (inline editor)

struct MidiCommandRow: View {
    @Binding var cmd: MidiCommand

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $cmd.type) {
                ForEach(MidiCommandType.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .labelsHidden()
            .frame(width: 130)

            Text("CH").font(.caption).foregroundColor(.secondary)
            TextField("1", value: $cmd.channel, formatter: channelFmt)
                .frame(width: 38)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())

            switch cmd.type {
            case .pc:
                Text("PC").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 44).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
            case .note:
                Text("Nr").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 44).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Text("Vel").font(.caption).foregroundColor(.secondary)
                TextField("127", value: $cmd.value2, formatter: midiFmt)
                    .frame(width: 44).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
            case .cc:
                Text("CC").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 44).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Text("Val").font(.caption).foregroundColor(.secondary)
                TextField("127", value: $cmd.value2, formatter: midiFmt)
                    .frame(width: 44).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
            }
        }
        // In grouped Forms (Settings) a TextField's title would otherwise render as an extra label.
        .labelsHidden()
    }

    private var midiFmt: NumberFormatter {
        let f = NumberFormatter(); f.minimum = 0; f.maximum = 127; f.allowsFloats = false; return f
    }
    private var channelFmt: NumberFormatter {
        let f = NumberFormatter(); f.minimum = 1; f.maximum = 16; f.allowsFloats = false; return f
    }
}

