import SwiftUI
import Combine
import CoreMIDI
import AppKit
import Network
import Security

// MARK: - Models

enum MidiCommandType: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }
    case note = "Note"
    case pc = "Program Change"
    case cc = "Control Change"
}

struct MidiCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: MidiCommandType = .pc
    var channel: Int = 1
    var value1: Int = 0
    var value2: Int = 127
}

// A single Nuendo track (e.g. "Nova HS") with its select command and version count
struct NuendoTrack: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neuer Kanal"
    var selectCommand: MidiCommand = MidiCommand()
    var versionCount: Int = 2
}

// A cast member: just a name and their position (1-based) in Nuendo's Track Versions list
struct CastMember: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neuer Darsteller"
    var versionPosition: Int = 1
}

struct Role: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neue Rolle"
    var emailKeyword: String = ""
    var tracks: [NuendoTrack] = []
    var members: [CastMember] = []
    var selectedMemberId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, emailKeyword, tracks, members, selectedMemberId
    }

    init(id: UUID = UUID(), name: String = "Neue Rolle", emailKeyword: String = "",
         tracks: [NuendoTrack] = [], members: [CastMember] = [], selectedMemberId: UUID? = nil) {
        self.id = id; self.name = name; self.emailKeyword = emailKeyword
        self.tracks = tracks; self.members = members; self.selectedMemberId = selectedMemberId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = (try? c.decodeIfPresent(UUID.self,          forKey: .id))             ?? UUID()
        name           = (try? c.decodeIfPresent(String.self,        forKey: .name))           ?? "Neue Rolle"
        emailKeyword   = (try? c.decodeIfPresent(String.self,        forKey: .emailKeyword))   ?? ""
        tracks         = (try? c.decodeIfPresent([NuendoTrack].self, forKey: .tracks))         ?? []
        members        = (try? c.decodeIfPresent([CastMember].self,  forKey: .members))        ?? []
        selectedMemberId = try? c.decodeIfPresent(UUID.self, forKey: .selectedMemberId)
    }
}

struct EmailConfig: Codable, Equatable {
    var imapServer: String = ""
    var imapPort: Int = 993
    var username: String = ""
}

struct AppConfig: Codable, Equatable {
    var delayMs: Int = 50
    var prevVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127)
    var nextVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127)
    var roles: [Role] = []
    var emailConfig: EmailConfig = EmailConfig()
    var midiOutputName: String = ""   // empty = virtual source

    enum CodingKeys: String, CodingKey {
        case delayMs, prevVersionCommand, nextVersionCommand, roles, emailConfig, midiOutputName
    }

    init(delayMs: Int = 50,
         prevVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127),
         nextVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127),
         roles: [Role] = [], emailConfig: EmailConfig = EmailConfig(), midiOutputName: String = "") {
        self.delayMs = delayMs
        self.prevVersionCommand = prevVersionCommand
        self.nextVersionCommand = nextVersionCommand
        self.roles = roles
        self.emailConfig = emailConfig
        self.midiOutputName = midiOutputName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delayMs            = (try? c.decodeIfPresent(Int.self,          forKey: .delayMs))            ?? 50
        prevVersionCommand = (try? c.decodeIfPresent(MidiCommand.self,  forKey: .prevVersionCommand)) ?? MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127)
        nextVersionCommand = (try? c.decodeIfPresent(MidiCommand.self,  forKey: .nextVersionCommand)) ?? MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127)
        roles              = (try? c.decodeIfPresent([Role].self,        forKey: .roles))              ?? []
        emailConfig        = (try? c.decodeIfPresent(EmailConfig.self,  forKey: .emailConfig))        ?? EmailConfig()
        midiOutputName     = (try? c.decodeIfPresent(String.self,       forKey: .midiOutputName))     ?? ""
    }
}

// MARK: - MIDI Controller

struct MIDIDestinationInfo: Identifiable, Equatable {
    let id: MIDIEndpointRef
    let name: String
}

class MidiController: ObservableObject {
    var midiClient: MIDIClientRef = 0
    var virtualSource: MIDIEndpointRef = 0
    var outputPort: MIDIPortRef = 0

    @Published var config: AppConfig = AppConfig()
    @Published var availableDestinations: [MIDIDestinationInfo] = []
    let configURL: URL

    init() {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("MidiCastSwitcher")
        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        configURL = appDir.appendingPathComponent("config.json")
        loadConfig()
        setupMIDI()
        refreshDestinations()
    }

    func setupMIDI() {
        let status = MIDIClientCreate("MidiCastSwitcherClient" as CFString, nil, nil, &midiClient)
        if status == noErr {
            MIDISourceCreate(midiClient, "MidiCastSwitcher Source" as CFString, &virtualSource)
            MIDIOutputPortCreate(midiClient, "MidiCastSwitcher Out" as CFString, &outputPort)
        }
    }

    func refreshDestinations() {
        let count = MIDIGetNumberOfDestinations()
        availableDestinations = (0..<count).compactMap { i in
            let dest = MIDIGetDestination(i)
            var nameRef: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(dest, kMIDIPropertyName, &nameRef) == noErr,
                  let name = nameRef?.takeRetainedValue() as String? else { return nil }
            return MIDIDestinationInfo(id: dest, name: name)
        }
    }

    // Resolve stored output name to a live MIDIEndpointRef
    private var selectedDestination: MIDIEndpointRef? {
        guard !config.midiOutputName.isEmpty else { return nil }
        return availableDestinations.first(where: { $0.name == config.midiOutputName })?.id
    }

    func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            let defaultRoles = [
                ("Aurora",  ["Aurora HS",  "Aurora TS"]),
                ("Nova", ["Nova HS", "Nova TS"]),
                ("Echo",   ["Echo HS",   "Echo TS"]),
                ("Luna",  ["Luna HS",  "Luna TS"]),
                ("Orion",  ["Orion HS",  "Orion TS"]),
                ("Iris",  ["Iris HS",  "Iris TS"]),
            ]
            self.config = AppConfig(roles: defaultRoles.map { (roleName, trackNames) in
                Role(name: roleName, tracks: trackNames.map { NuendoTrack(name: $0) })
            })
        }
    }

    func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            try? encoded.write(to: configURL)
        }
    }

    // Builds and fires the complete MIDI sequence for all selected cast members.
    // For each role's selected member, and for each track in that role:
    //   1. Send selectCommand to choose the track in Nuendo
    //   2. Send prevVersionCommand × (versionCount - 1) to reset to the first version
    //   3. Send nextVersionCommand × (versionPosition - 1) to navigate to the desired version
    func fireMidi() {
        var sequence: [MidiCommand] = []

        for role in config.roles {
            guard let selId = role.selectedMemberId,
                  let member = role.members.first(where: { $0.id == selId }) else { continue }

            for track in role.tracks {
                sequence.append(track.selectCommand)
                let resetSteps = max(0, track.versionCount - 1)
                for _ in 0..<resetSteps {
                    sequence.append(config.prevVersionCommand)
                }
                let forwardSteps = max(0, member.versionPosition - 1)
                for _ in 0..<forwardSteps {
                    sequence.append(config.nextVersionCommand)
                }
            }
        }

        for (i, cmd) in sequence.enumerated() {
            let delay = Double(i * config.delayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.send(command: cmd)
            }
        }
    }

    func send(command: MidiCommand) {
        let statusByte: UInt8
        switch command.type {
        case .note: statusByte = 0x90 + UInt8(command.channel - 1)
        case .pc:   statusByte = 0xC0 + UInt8(command.channel - 1)
        case .cc:   statusByte = 0xB0 + UInt8(command.channel - 1)
        }
        let b2 = UInt8(command.value1 & 0x7F)
        let b3 = UInt8(command.value2 & 0x7F)
        let bytes: [UInt8] = command.type == .pc ? [statusByte, b2] : [statusByte, b2, b3]

        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)

        if let dest = selectedDestination {
            MIDISend(outputPort, dest, &packetList)
        } else {
            MIDIReceived(virtualSource, &packetList)
        }

        if command.type == .note {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var offList = MIDIPacketList()
                var offPkt = MIDIPacketListInit(&offList)
                let off: [UInt8] = [0x80 + UInt8(command.channel - 1), b2, 0]
                offPkt = MIDIPacketListAdd(&offList, 1024, offPkt, 0, off.count, off)
                if let dest = self.selectedDestination {
                    MIDISend(self.outputPort, dest, &offList)
                } else {
                    MIDIReceived(self.virtualSource, &offList)
                }
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct MidiCastSwitcherApp: App {
    @StateObject private var midi = MidiController()
    @StateObject private var emailClient = IMAPClient()

    var body: some Scene {
        // Compact live window — stays on top of Nuendo
        WindowGroup("MCS Live", id: "live") {
            LiveView(midi: midi, emailClient: emailClient)
                .onAppear { setupLiveWindow() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 280, height: 380)

        // Single config window — Window (not WindowGroup) ensures only one instance
        Window("MCS Einstellungen", id: "config") {
            ConfigView(midi: midi, emailClient: emailClient)
        }
        .windowResizability(.contentSize)

        // Email import window
        Window("MCS Email Import", id: "email") {
            EmailView(midi: midi, emailClient: emailClient)
        }
        .windowResizability(.contentSize)
    }

    private func setupLiveWindow() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if window.title.contains("Live") || window.title == "MCS" {
                    window.level = .floating
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    window.titlebarAppearsTransparent = true
                    window.isMovableByWindowBackground = true
                }
            }
        }
    }
}

// MARK: - Live View

struct LiveView: View {
    @ObservedObject var midi: MidiController
    @ObservedObject var emailClient: IMAPClient
    @State private var fireScale: CGFloat = 1.0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Title bar row
            HStack {
                Text("MCS")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                // Quick import: fetch + apply immediately, then open email window
                Button {
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
                } label: {
                    Image(systemName: "envelope.open.fill")
                        .font(.system(size: 13))
                        .foregroundColor(emailClient.isFetching ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Besetzung sofort aus Email importieren")
                Button {
                    openWindow(id: "config")
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Einstellungen öffnen")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Role rows
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($midi.config.roles) { $role in
                        HStack(spacing: 8) {
                            Text(role.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 52, alignment: .leading)
                                .lineLimit(1)

                            Picker("", selection: $role.selectedMemberId) {
                                Text("—").tag(UUID?.none)
                                ForEach(role.members.sorted { $0.versionPosition < $1.versionPosition }) { member in
                                    Text(member.name).tag(UUID?.some(member.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(rowBackground(for: role))
                        .cornerRadius(7)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Send to Nuendo button
            Button(action: {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { fireScale = 0.95 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { fireScale = 1.0 }
                }
                midi.fireMidi()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Send to Nuendo")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.accentColor)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .scaleEffect(fireScale)
            .padding(10)
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
        .onChange(of: midi.config) { midi.saveConfig() }
    }

    private func rowBackground(for role: Role) -> Color {
        role.selectedMemberId == nil
            ? Color.secondary.opacity(0.07)
            : Color.accentColor.opacity(0.12)
    }
}

// MARK: - Config View

struct ConfigView: View {
    @ObservedObject var midi: MidiController
    @ObservedObject var emailClient: IMAPClient
    @State private var selectedRoleId: UUID? = nil
    @State private var emailPassword = ""

    private let leftW: CGFloat  = 340
    private let totalH: CGFloat = 580

    var body: some View {
        HStack(spacing: 0) {
            // Left panel: role list + global navigation settings
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Rollen")
                        .font(.headline)
                        .padding([.horizontal, .top], 14)
                        .padding(.bottom, 6)

                    List(selection: $selectedRoleId) {
                        ForEach($midi.config.roles) { $role in
                            VStack(alignment: .leading, spacing: 3) {
                                TextField("Rollen Name", text: $role.name)
                                    .font(.system(size: 13, weight: .semibold))
                                HStack(spacing: 4) {
                                    Text("Keyword:")
                                        .font(.caption2).foregroundColor(.secondary)
                                    TextField("z.B. AURORA", text: $role.emailKeyword)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .tag(role.id)
                            .padding(.vertical, 2)
                        }
                        .onDelete { midi.config.roles.remove(atOffsets: $0) }
                    }
                    .frame(height: max(100, CGFloat(midi.config.roles.count) * 34 + 8))

                    HStack {
                        Button("+ Rolle") {
                            let r = Role()
                            midi.config.roles.append(r)
                            selectedRoleId = r.id
                        }
                        .buttonStyle(.bordered)
                        Button("Löschen") {
                            if let id = selectedRoleId {
                                midi.config.roles.removeAll { $0.id == id }
                                selectedRoleId = nil
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedRoleId == nil)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Nuendo Navigation")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("MIDI Ausgang:")
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Button { midi.refreshDestinations() } label: {
                                    Image(systemName: "arrow.clockwise").font(.caption)
                                }
                                .buttonStyle(.plain).foregroundColor(.secondary)
                            }
                            Picker("", selection: $midi.config.midiOutputName) {
                                Text("Virtual Source (MidiCastSwitcher)").tag("")
                                ForEach(midi.availableDestinations) { dest in
                                    Text(dest.name).tag(dest.name)
                                }
                            }
                            .labelsHidden()
                        }

                        HStack {
                            Text("Verzögerung:")
                                .font(.caption).foregroundColor(.secondary)
                            TextField("ms", value: $midi.config.delayMs, formatter: NumberFormatter())
                                .frame(width: 54)
                                .textFieldStyle(.roundedBorder)
                            Text("ms").font(.caption).foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("↑ Vorherige Track Version")
                                .font(.caption).foregroundColor(.secondary)
                            MidiCommandRow(cmd: $midi.config.prevVersionCommand)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("↓ Nächste Track Version")
                                .font(.caption).foregroundColor(.secondary)
                            MidiCommandRow(cmd: $midi.config.nextVersionCommand)
                        }
                    }
                    .padding(14)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: "envelope").font(.system(size: 12))
                                Image(systemName: "gearshape.fill").font(.system(size: 6)).offset(x: 4, y: 3)
                            }
                            Text("Email Import").font(.headline)
                        }

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Server").font(.caption).foregroundColor(.secondary)
                                TextField("imap.gmx.de", text: $midi.config.emailConfig.imapServer)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Port").font(.caption).foregroundColor(.secondary)
                                TextField("993", value: $midi.config.emailConfig.imapPort, formatter: NumberFormatter())
                                    .textFieldStyle(.roundedBorder).frame(width: 60)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Benutzername").font(.caption).foregroundColor(.secondary)
                            TextField("name@gmx.de", text: $midi.config.emailConfig.username)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Passwort").font(.caption).foregroundColor(.secondary)
                            SecureField("Passwort", text: $emailPassword)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Spacer()
                            Button("Speichern") {
                                keychainSave(account: midi.config.emailConfig.username, secret: emailPassword)
                                midi.saveConfig()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                    .onAppear { emailPassword = keychainLoad(account: midi.config.emailConfig.username) ?? "" }
                }
            }
            .frame(width: leftW, height: totalH)

            Divider()

            // Right panel: role detail
            Group {
                if let idx = midi.config.roles.firstIndex(where: { $0.id == selectedRoleId }) {
                    RoleDetailView(role: $midi.config.roles[idx], height: totalH)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.left")
                            .font(.largeTitle)
                            .foregroundColor(.secondary.opacity(0.3))
                        Text("Rolle links auswählen")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: midi.config) { midi.saveConfig() }
    }
}

// MARK: - Role Detail View

struct RoleDetailView: View {
    @Binding var role: Role
    let height: CGFloat
    @State private var selectedMemberId: UUID? = nil

    private let trackW: CGFloat  = 360
    private let memberW: CGFloat = 260

    private func nextFreePosition() -> Int {
        let used = Set(role.members.map { $0.versionPosition })
        var pos = 1
        while used.contains(pos) { pos += 1 }
        return pos
    }

    private func setPosition(for memberId: UUID, to newPos: Int) {
        guard let idx = role.members.firstIndex(where: { $0.id == memberId }) else { return }
        let oldPos = role.members[idx].versionPosition
        if let conflictIdx = role.members.firstIndex(where: {
            $0.versionPosition == newPos && $0.id != memberId
        }) {
            role.members[conflictIdx].versionPosition = oldPos
        }
        role.members[idx].versionPosition = newPos
    }

    var body: some View {
        HStack(spacing: 0) {
            // Tracks column
            VStack(alignment: .leading, spacing: 0) {
                Text("Nuendo-Kanäle")
                    .font(.headline)
                    .padding([.horizontal, .top], 12)
                    .padding(.bottom, 6)

                List {
                    ForEach($role.tracks) { $track in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Kanal Name", text: $track.name)
                                .font(.system(size: 13, weight: .semibold))

                            HStack(spacing: 8) {
                                Text("Versionen:")
                                    .font(.caption).foregroundColor(.secondary)
                                Text("\(track.versionCount)")
                                    .frame(width: 22, alignment: .trailing)
                                    .font(.caption)
                                Stepper("", value: $track.versionCount, in: 1...32)
                                    .labelsHidden()
                            }

                            Text("Auswahl-Befehl:")
                                .font(.caption).foregroundColor(.secondary)
                            MidiCommandRow(cmd: $track.selectCommand)
                        }
                        .padding(.vertical, 6)
                    }
                    .onDelete { role.tracks.remove(atOffsets: $0) }
                }

                HStack {
                    Button("+ Kanal") { role.tracks.append(NuendoTrack()) }
                        .buttonStyle(.bordered)
                }
                .padding(10)
            }
            .frame(width: trackW, height: height)

            Divider()

            // Members column
            VStack(alignment: .leading, spacing: 0) {
                Text("Darsteller")
                    .font(.headline)
                    .padding([.horizontal, .top], 12)
                    .padding(.bottom, 6)

                List(selection: $selectedMemberId) {
                    let sortedIndices = role.members.indices.sorted { role.members[$0].versionPosition < role.members[$1].versionPosition }
                    ForEach(sortedIndices, id: \.self) { idx in
                        let member = role.members[idx]
                        HStack(spacing: 8) {
                            TextField("Name", text: Binding(
                                get: { role.members[idx].name },
                                set: { role.members[idx].name = $0 }
                            ))
                            Spacer()
                            Text("Slot")
                                .font(.caption).foregroundColor(.secondary)
                            Text("\(member.versionPosition)")
                                .frame(width: 24, alignment: .trailing)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Stepper("", value: Binding(
                                get: { member.versionPosition },
                                set: { setPosition(for: member.id, to: $0) }
                            ), in: 1...32)
                            .labelsHidden()
                        }
                        .tag(member.id)
                    }
                    .onDelete { offsets in
                        let sorted = role.members.indices.sorted { role.members[$0].versionPosition < role.members[$1].versionPosition }
                        let toRemove = offsets.map { sorted[$0] }
                        role.members.remove(atOffsets: IndexSet(toRemove))
                    }
                }

                HStack {
                    Button("+ Darsteller") {
                        var m = CastMember()
                        m.versionPosition = nextFreePosition()
                        role.members.append(m)
                        selectedMemberId = m.id
                        // Auto-raise versionCount on all tracks to cover the new member count
                        let count = role.members.count
                        for i in role.tracks.indices where role.tracks[i].versionCount < count {
                            role.tracks[i].versionCount = count
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)

                if let member = role.members.first(where: { $0.id == selectedMemberId }) {
                    Divider()
                    MidiSequencePreview(role: role, member: member)
                }
            }
            .frame(width: memberW, height: height)
        }
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
                .padding(.horizontal, 10)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
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
        for track in role.tracks {
            out.append("[\(track.name)] → \(cmdStr(track.selectCommand))")
            let r = max(0, track.versionCount - 1)
            if r > 0 { out.append("  ↑ Prev ×\(r)  (auf Anfang)") }
            let f = max(0, member.versionPosition - 1)
            if f > 0 { out.append("  ↓ Next ×\(f)  → Pos \(member.versionPosition)") }
            else      { out.append("  → Pos 1 (erste Version)") }
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
                .frame(width: 28)
                .textFieldStyle(.roundedBorder)

            switch cmd.type {
            case .pc:
                Text("PC").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 36).textFieldStyle(.roundedBorder)
            case .note:
                Text("Nr").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 36).textFieldStyle(.roundedBorder)
                Text("Vel").font(.caption).foregroundColor(.secondary)
                TextField("127", value: $cmd.value2, formatter: midiFmt)
                    .frame(width: 36).textFieldStyle(.roundedBorder)
            case .cc:
                Text("CC").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 36).textFieldStyle(.roundedBorder)
                Text("Val").font(.caption).foregroundColor(.secondary)
                TextField("127", value: $cmd.value2, formatter: midiFmt)
                    .frame(width: 36).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var midiFmt: NumberFormatter {
        let f = NumberFormatter(); f.minimum = 0; f.maximum = 127; f.allowsFloats = false; return f
    }
    private var channelFmt: NumberFormatter {
        let f = NumberFormatter(); f.minimum = 1; f.maximum = 16; f.allowsFloats = false; return f
    }
}

// MARK: - Keychain

private let kKeychainService = "com.janos.MCS.imap"

func keychainSave(account: String, secret: String) {
    guard let data = secret.data(using: .utf8) else { return }
    let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                               kSecAttrService: kKeychainService as CFString,
                               kSecAttrAccount: account as CFString]
    SecItemDelete(q as CFDictionary)
    var add = q; add[kSecValueData] = data
    SecItemAdd(add as CFDictionary, nil)
}

func keychainLoad(account: String) -> String? {
    let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                               kSecAttrService: kKeychainService as CFString,
                               kSecAttrAccount: account as CFString,
                               kSecReturnData: true,
                               kSecMatchLimit: kSecMatchLimitOne]
    var result: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - IMAP Client

enum IMAPError: LocalizedError {
    case connectionFailed(String), authFailed, noEmailFound, fetchFailed
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Verbindung fehlgeschlagen: \(m)"
        case .authFailed:              return "Anmeldung fehlgeschlagen. Zugangsdaten prüfen."
        case .noEmailFound:            return "Keine 'Cast Information' Email gefunden."
        case .fetchFailed:             return "Email-Inhalt konnte nicht geladen werden."
        }
    }
}

class IMAPClient: ObservableObject {
    @Published var isFetching = false
    @Published var statusMessage = ""
    @Published var rawEmailText = ""
    @Published var parsedRows: [(keyword: String, name: String)] = []
    @Published var fetchError: String? = nil
    @Published var openInSettings = false
    @Published var pending: [UUID: UUID?] = [:]

    func buildPending(roles: [Role]) {
        pending = [:]
        for role in roles {
            guard let row = parsedRows.first(where: {
                $0.keyword.uppercased() == role.emailKeyword.uppercased()
            }) else { continue }
            let first = row.name.components(separatedBy: " ").first?.lowercased() ?? ""
            let match = role.members.first {
                ($0.name.components(separatedBy: " ").first?.lowercased() ?? "") == first
                    || $0.name.lowercased().contains(first)
            }
            pending[role.id] = match?.id
        }
    }

    func applyAssignments(to config: inout AppConfig) {
        for (roleId, memberId) in pending {
            if let idx = config.roles.firstIndex(where: { $0.id == roleId }) {
                config.roles[idx].selectedMemberId = memberId
            }
        }
    }

    func fetch(config: EmailConfig, password: String, keywords: [String]) async {
        guard !config.imapServer.isEmpty, !config.username.isEmpty, !password.isEmpty else {
            fetchError = "Bitte Server, Benutzername und Passwort eingeben."
            return
        }
        isFetching = true; fetchError = nil; rawEmailText = ""; parsedRows = []
        statusMessage = "Verbinde mit \(config.imapServer):\(config.imapPort)…"
        do {
            let (raw, rows) = try await imapFetch(server: config.imapServer,
                                                  port: UInt16(config.imapPort),
                                                  username: config.username,
                                                  password: password,
                                                  keywords: keywords)
            rawEmailText = raw
            parsedRows = rows
            statusMessage = rows.isEmpty ? "Keine Rollen erkannt." : "\(rows.count) Rolle(n) erkannt."
        } catch let e as IMAPError {
            fetchError = e.errorDescription; statusMessage = "Fehler"
        } catch {
            fetchError = error.localizedDescription; statusMessage = "Fehler"
        }
        isFetching = false
    }

    private func imapFetch(server: String, port: UInt16, username: String, password: String,
                           keywords: [String]) async throws -> (String, [(keyword: String, name: String)]) {
        let conn = NWConnection(to: .hostPort(host: .init(server), port: .init(rawValue: port)!), using: .tls)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:               done = true; cont.resume()
                case .failed(let e):       done = true; cont.resume(throwing: IMAPError.connectionFailed(e.localizedDescription))
                case .cancelled:           done = true; cont.resume(throwing: IMAPError.connectionFailed("Abgebrochen"))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        defer { conn.cancel() }

        var buf = Data()

        func recvChunk() async throws -> Data {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, done, err in
                    if let err { cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription)) }
                    else if let d = data, !d.isEmpty { cont.resume(returning: d) }
                    else if done { cont.resume(throwing: IMAPError.connectionFailed("Verbindung getrennt")) }
                    else { cont.resume(returning: Data()) }
                }
            }
        }

        func readLine() async throws -> String {
            while true {
                if let r = buf.range(of: Data("\r\n".utf8)) {
                    let s = String(data: buf[..<r.lowerBound], encoding: .utf8) ?? ""
                    buf.removeSubrange(..<r.upperBound); return s
                }
                buf.append(try await recvChunk())
            }
        }

        func readBytes(_ n: Int) async throws -> Data {
            while buf.count < n { buf.append(try await recvChunk()) }
            let out = Data(buf[..<n]); buf.removeSubrange(..<n); return out
        }

        func readUntilTagged(_ tag: String) async throws -> [String] {
            var lines: [String] = []
            while true { let l = try await readLine(); lines.append(l); if l.hasPrefix(tag + " ") { break } }
            return lines
        }

        func send(_ cmd: String) async throws {
            let data = (cmd + "\r\n").data(using: .utf8)!
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { err in
                    if let err { cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription)) }
                    else { cont.resume() }
                })
            }
        }

        var tagN = 0
        func tag() -> String { tagN += 1; return "T\(tagN)" }
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

        _ = try await readLine() // greeting

        let t1 = tag()
        try await send("\(t1) LOGIN \"\(esc(username))\" \"\(esc(password))\"")
        guard (try await readUntilTagged(t1)).last?.hasPrefix("\(t1) OK") == true else { throw IMAPError.authFailed }

        let t2 = tag()
        try await send("\(t2) SELECT INBOX")
        _ = try await readUntilTagged(t2)

        let t3 = tag()
        try await send("\(t3) SEARCH SUBJECT \"Cast Information\"")
        let searchLines = try await readUntilTagged(t3)
        let msgIds = searchLines.first(where: { $0.hasPrefix("* SEARCH") })
            .flatMap { line -> [Int]? in
                line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").compactMap { Int($0) } as [Int]
            } ?? []
        guard let latest = msgIds.max() else { throw IMAPError.noEmailFound }

        var bodyText = ""
        for part in ["BODY[TEXT]", "BODY[2]", "BODY[1.2]", "BODY[1]"] {
            let t = tag()
            try await send("\(t) FETCH \(latest) (\(part))")
            var fetched = ""
            while true {
                let line = try await readLine()
                if let r = line.range(of: #"\{(\d+)\}$"#, options: .regularExpression),
                   let count = Int(line[r].dropFirst().dropLast()) {
                    let raw = try await readBytes(count)
                    fetched = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
                }
                if line.hasPrefix(t + " ") { break }
            }
            if !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodyText = fetched; break
            }
        }
        guard !bodyText.isEmpty else { throw IMAPError.fetchFailed }

        let t5 = tag()
        try await send("\(t5) LOGOUT")

        let decoded = decodeBody(bodyText)
        let plain   = htmlToPlainText(decoded)
        return (plain, extractAssignments(from: plain, keywords: keywords))
    }

    private func decodeBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let b64 = trimmed.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
        if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           s.count > 50 { return s }
        if trimmed.contains("=") {
            var out = ""
            let src = trimmed.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
            var i = src.startIndex
            while i < src.endIndex {
                if src[i] == "=", src.distance(from: i, to: src.endIndex) >= 3 {
                    let hex = String(src[src.index(i, offsetBy: 1)..<src.index(i, offsetBy: 3)])
                    if let byte = UInt8(hex, radix: 16) { out.append(Character(UnicodeScalar(byte))); i = src.index(i, offsetBy: 3); continue }
                }
                out.append(src[i]); i = src.index(after: i)
            }
            if out != src { return out }
        }
        return body
    }

    private func htmlToPlainText(_ html: String) -> String {
        guard html.contains("<"), let data = html.data(using: .utf8) else { return html }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) { return attr.string }
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                   .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    private func extractAssignments(from text: String, keywords: [String]) -> [(keyword: String, name: String)] {
        var results: [(keyword: String, name: String)] = []

        // Normalize: non-breaking spaces and tabs → regular space
        let normalized = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let allKw = keywords.map { $0.uppercased() }
        let skipWords = ["SOLOISTS", "ACROBATICS", "1. ACT", "2. ACT", "LAST UPDATED", "FLOATING"]

        for keyword in keywords where !keyword.isEmpty {
            let kw = keyword.uppercased()
            for (i, line) in lines.enumerated() {
                let up = line.uppercased()
                guard up == kw || up.hasPrefix(kw + " ") else { continue }

                var candidate = ""
                if up == kw {
                    // Keyword alone on its line — name follows on next useful line
                    for j in (i+1)..<min(i+4, lines.count) {
                        let next = lines[j]
                        let nu = next.uppercased()
                        if allKw.contains(where: { nu == $0 || nu.hasPrefix($0 + " ") }) { break }
                        if skipWords.contains(where: { nu.contains($0) }) { continue }
                        candidate = next; break
                    }
                } else {
                    // "KEYWORD <sep> Name" format — strip optional dash/colon separator
                    var rest = String(line.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
                    for sep in ["- ", "– ", ": "] {
                        if rest.hasPrefix(sep) {
                            rest = String(rest.dropFirst(sep.count)).trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                    // "NOVA - Paul // LUNA - Max" → take only first segment
                    if let slashIdx = rest.range(of: " //") {
                        rest = String(rest[..<slashIdx.lowerBound]).trimmingCharacters(in: .whitespaces)
                    }
                    candidate = rest
                }

                if !candidate.isEmpty {
                    results.append((keyword: keyword, name: candidate))
                }
                break
            }
        }
        return results
    }
}

// MARK: - Email View

struct EmailView: View {
    @ObservedObject var midi: MidiController
    @ObservedObject var emailClient: IMAPClient
    @State private var password = ""

    private var imap: IMAPClient { emailClient }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cast Email Import")
                        .font(.headline)
                    Text(imap.statusMessage.isEmpty ? "Bereit" : imap.statusMessage)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if imap.isFetching { ProgressView().scaleEffect(0.7) }
                Button("E-Mail abrufen") {
                    let pw = password.isEmpty ? (keychainLoad(account: midi.config.emailConfig.username) ?? "") : password
                    Task {
                        await imap.fetch(config: midi.config.emailConfig, password: pw,
                                         keywords: midi.config.roles.map { $0.emailKeyword })
                        emailClient.buildPending(roles: midi.config.roles)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(imap.isFetching)
            }
            .padding(14)

            if let err = imap.fetchError {
                HStack { Image(systemName: "exclamationmark.triangle").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red) }
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }

            Divider()

            mainPanel
        }
        .frame(width: 820, height: 560)
        .onAppear {
            password = keychainLoad(account: midi.config.emailConfig.username) ?? ""
        }
    }

    @ViewBuilder private var mainPanel: some View {
        HStack(spacing: 0) {
            // Left: original email text
            VStack(alignment: .leading, spacing: 0) {
                Text("Original Email").font(.caption.bold()).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        if imap.rawEmailText.isEmpty {
                            Text("Noch keine Email geladen.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(12)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(imap.rawEmailText.components(separatedBy: "\n").enumerated()), id: \.offset) { idx, line in
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                            .padding(12)
                        }
                    }
                    .onChange(of: imap.rawEmailText) { text in
                        let lines = text.components(separatedBy: "\n")
                        if let idx = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("last updated") }) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation { proxy.scrollTo(max(0, idx - 1), anchor: .top) }
                            }
                        }
                    }
                }
            }
            .frame(width: 380)

            Divider()

            // Right: confirmation of parsed assignments
            VStack(alignment: .leading, spacing: 0) {
                Text("Erkannte Besetzung — bitte bestätigen")
                    .font(.caption.bold()).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()

                if imap.parsedRows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: imap.rawEmailText.isEmpty ? "envelope.open" : "questionmark.circle")
                            .font(.largeTitle).foregroundColor(.secondary.opacity(0.4))
                        Text(imap.rawEmailText.isEmpty
                             ? "Email abrufen um Besetzung zu importieren."
                             : "Keine Rollen erkannt.\nEmail-Schlüsselwörter in den Einstellungen prüfen.")
                            .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(midi.config.roles) { role in
                            if let row = imap.parsedRows.first(where: {
                                $0.keyword.uppercased() == role.emailKeyword.uppercased()
                            }) {
                                let unmatched = emailClient.pending[role.id] == nil || emailClient.pending[role.id]! == nil
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(role.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(unmatched ? .red : .primary)
                                        Text("erkannt: \"\(row.name)\"")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Picker("", selection: Binding(
                                        get: { emailClient.pending[role.id] ?? nil },
                                        set: { emailClient.pending[role.id] = $0 }
                                    )) {
                                        Text("—").tag(UUID?.none)
                                        ForEach(role.members) { m in Text(m.name).tag(UUID?.some(m.id)) }
                                    }
                                    .labelsHidden().frame(width: 150)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Divider()
                    HStack {
                        Spacer()
                        Button("Besetzung übernehmen") { applyAssignments() }
                            .buttonStyle(.borderedProminent)
                            .disabled(emailClient.pending.values.allSatisfy { $0 == nil })
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func applyAssignments() {
        emailClient.applyAssignments(to: &midi.config)
        midi.saveConfig()
    }
}
