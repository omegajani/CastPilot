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
    /// Slot-centric assignment: index `i` holds the memberId (uuidString) at slot `i+1`, or nil if empty.
    /// `slotAssignments.count` is kept equal to `versionCount`.
    var slotAssignments: [String?] = [nil, nil]
    /// Legacy: pre-1.3 stored per-track overrides keyed by memberId. Kept for one-time migration on load.
    var slotOverrides: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case id, name, selectCommand, versionCount, slotAssignments, slotOverrides
    }

    init(id: UUID = UUID(), name: String = "Neuer Kanal",
         selectCommand: MidiCommand = MidiCommand(),
         versionCount: Int = 2,
         slotAssignments: [String?]? = nil,
         slotOverrides: [String: Int] = [:]) {
        self.id = id; self.name = name
        self.selectCommand = selectCommand
        self.versionCount = versionCount
        self.slotAssignments = slotAssignments ?? Array(repeating: nil, count: versionCount)
        self.slotOverrides = slotOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = (try? c.decodeIfPresent(UUID.self,           forKey: .id))            ?? UUID()
        name           = (try? c.decodeIfPresent(String.self,         forKey: .name))          ?? "Neuer Kanal"
        selectCommand  = (try? c.decodeIfPresent(MidiCommand.self,    forKey: .selectCommand)) ?? MidiCommand()
        versionCount   = (try? c.decodeIfPresent(Int.self,            forKey: .versionCount))  ?? 2
        slotOverrides  = (try? c.decodeIfPresent([String: Int].self,  forKey: .slotOverrides)) ?? [:]
        if let decoded = try? c.decodeIfPresent([String?].self, forKey: .slotAssignments) {
            slotAssignments = decoded
        } else {
            // Initialize empty; migration from legacy versionPosition + slotOverrides happens in
            // MidiController.loadConfig() once members are available.
            slotAssignments = Array(repeating: nil, count: versionCount)
        }
        // Normalize length
        if slotAssignments.count < versionCount {
            slotAssignments.append(contentsOf: Array(repeating: nil, count: versionCount - slotAssignments.count))
        } else if slotAssignments.count > versionCount {
            slotAssignments = Array(slotAssignments.prefix(versionCount))
        }
    }

    /// Returns the 1-based slot of a member in this track, or nil if the member isn't assigned here.
    func slot(of memberId: UUID) -> Int? {
        if let idx = slotAssignments.firstIndex(of: memberId.uuidString) {
            return idx + 1
        }
        return nil
    }

    /// Sets a member to a specific slot. Removes the member from any other slot in this track first
    /// (one member can only occupy one slot per track).
    mutating func setMember(_ memberId: UUID?, atSlot slot: Int) {
        guard slot >= 1 && slot <= versionCount else { return }
        // Defensive: guarantee the backing array matches versionCount, otherwise the
        // slotAssignments[idx] write below could crash if a previous mutation raised
        // versionCount but forgot to sync.
        syncSlotAssignmentsToVersionCount()
        let idx = slot - 1
        // If we're assigning a real member, clear them from any other slot first.
        if let mid = memberId?.uuidString {
            for i in slotAssignments.indices where slotAssignments[i] == mid && i != idx {
                slotAssignments[i] = nil
            }
            slotAssignments[idx] = mid
        } else {
            slotAssignments[idx] = nil
        }
    }

    /// Adjusts slotAssignments length to match versionCount (preserves existing entries).
    mutating func syncSlotAssignmentsToVersionCount() {
        if slotAssignments.count < versionCount {
            slotAssignments.append(contentsOf: Array(repeating: nil, count: versionCount - slotAssignments.count))
        } else if slotAssignments.count > versionCount {
            slotAssignments = Array(slotAssignments.prefix(versionCount))
        }
    }
}

// A cast member: just a name and their position (1-based) in Nuendo's Track Versions list.
// `coverVariantOf` points to another principal in the same role; if set, this member is
// the "ballet variant" of that principal — used automatically when a cover borrows the
// principal's playback. Variant members never appear in the live picker.
struct CastMember: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neuer Darsteller"
    var versionPosition: Int = 1
    var coverVariantOf: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, versionPosition, coverVariantOf
    }

    init(id: UUID = UUID(), name: String = "Neuer Darsteller",
         versionPosition: Int = 1, coverVariantOf: UUID? = nil) {
        self.id = id; self.name = name
        self.versionPosition = versionPosition
        self.coverVariantOf = coverVariantOf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = (try? c.decodeIfPresent(UUID.self,   forKey: .id))              ?? UUID()
        name            = (try? c.decodeIfPresent(String.self, forKey: .name))            ?? "Neuer Darsteller"
        versionPosition = (try? c.decodeIfPresent(Int.self,    forKey: .versionPosition)) ?? 1
        coverVariantOf  = try? c.decodeIfPresent(UUID.self,    forKey: .coverVariantOf)
    }
}

/// A Cover (ballet double) doesn't have their own track version. They borrow the playback
/// of a principal — either a fixed one or, dynamically, the principal who is absent today.
struct Cover: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neuer Cover"
    /// nil → dynamic: at fire time, pick the principal not selected anywhere.
    /// non-nil → fixed: always use this principal's slot for this cover.
    var fixedSourceMemberId: UUID? = nil
}

struct Role: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neue Rolle"
    var emailKeyword: String = ""
    var tracks: [NuendoTrack] = []
    var members: [CastMember] = []
    var covers: [Cover] = []
    var selectedMemberId: UUID? = nil
    /// When set, this role sings the lines of the linked role whenever that role is "cut".
    /// In that case the Ballett-variant track versions are preferred (they contain the combined playback).
    var borrowsLinesFromRoleId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, emailKeyword, tracks, members, covers, selectedMemberId, borrowsLinesFromRoleId
    }

    init(id: UUID = UUID(), name: String = "Neue Rolle", emailKeyword: String = "",
         tracks: [NuendoTrack] = [], members: [CastMember] = [],
         covers: [Cover] = [], selectedMemberId: UUID? = nil,
         borrowsLinesFromRoleId: UUID? = nil) {
        self.id = id; self.name = name; self.emailKeyword = emailKeyword
        self.tracks = tracks; self.members = members
        self.covers = covers; self.selectedMemberId = selectedMemberId
        self.borrowsLinesFromRoleId = borrowsLinesFromRoleId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = (try? c.decodeIfPresent(UUID.self,          forKey: .id))             ?? UUID()
        name           = (try? c.decodeIfPresent(String.self,        forKey: .name))           ?? "Neue Rolle"
        emailKeyword   = (try? c.decodeIfPresent(String.self,        forKey: .emailKeyword))   ?? ""
        tracks         = (try? c.decodeIfPresent([NuendoTrack].self, forKey: .tracks))         ?? []
        members        = (try? c.decodeIfPresent([CastMember].self,  forKey: .members))        ?? []
        covers         = (try? c.decodeIfPresent([Cover].self,       forKey: .covers))         ?? []
        selectedMemberId      = try? c.decodeIfPresent(UUID.self, forKey: .selectedMemberId)
        borrowsLinesFromRoleId = try? c.decodeIfPresent(UUID.self, forKey: .borrowsLinesFromRoleId)
    }

    /// Returns true when the role this role borrows lines from currently has "cut" selected.
    /// In that case fireMidi() will prefer the Ballett-variant track versions.
    func borrowedRoleIsCut(allRoles: [Role]) -> Bool {
        guard let borrowedId = borrowsLinesFromRoleId,
              let borrowedRole = allRoles.first(where: { $0.id == borrowedId }),
              let selId = borrowedRole.selectedMemberId,
              let selMember = borrowedRole.members.first(where: { $0.id == selId })
        else { return false }
        return selMember.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "cut"
    }

    /// Resolves which principal's playback should be used right now.
    /// Returns the principal, whether the selection is a cover (for UI hints), and whether
    /// the dynamic resolution was ambiguous (multiple principals absent → first one used).
    func resolvePlaybackSource(allRoles: [Role]) -> (member: CastMember, isCover: Bool, ambiguous: Bool)? {
        guard let selId = selectedMemberId else { return nil }
        // Direct hit on a principal.
        if let m = members.first(where: { $0.id == selId }) {
            return (m, false, false)
        }
        // Otherwise it's a cover.
        guard let cover = covers.first(where: { $0.id == selId }) else { return nil }
        if let fixed = cover.fixedSourceMemberId,
           let m = members.first(where: { $0.id == fixed }) {
            return (m, true, false)
        }
        // Dynamic resolution: among real principals (variants excluded), find those whose
        // PERSON is not physically present anywhere in the show. Same person can appear
        // under the same name in multiple roles (e.g. Sofia in Aurora and Echo as separate
        // CastMember rows with different UUIDs but the same name) — so we match by name.
        // Cover selections don't count as "present" (the person isn't physically there;
        // their playback is just being borrowed).
        func normalized(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let liveNames: Set<String> = Set(
            allRoles.compactMap { otherRole -> String? in
                guard let selId = otherRole.selectedMemberId else { return nil }
                // Only count Principal selections (not Covers, not Variants).
                guard let m = otherRole.members.first(where: {
                    $0.id == selId && $0.coverVariantOf == nil
                }) else { return nil }
                return normalized(m.name)
            }
        )
        let absent = members
            .filter { $0.coverVariantOf == nil && !liveNames.contains(normalized($0.name)) }
            .sorted { $0.versionPosition < $1.versionPosition }
        guard let first = absent.first else { return nil }
        return (first, true, absent.count > 1)
    }
}

struct EmailConfig: Codable, Equatable {
    var imapServer: String = ""
    var imapPort: Int = 993
    var username: String = ""
}

struct AppConfig: Codable, Equatable {
    /// Pause between consecutive MIDI commands. Empirically Nuendo's MIDI Remote works
    /// better with short, snappy gaps than long pauses.
    var delayMs: Int = 100
    /// Extra pause inserted between role command-blocks. Originally added to give Nuendo
    /// breathing room, but in practice short gaps work fine here too.
    var interRoleDelayMs: Int = 100
    var prevVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127)
    var nextVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127)
    var roles: [Role] = []
    var emailConfig: EmailConfig = EmailConfig()
    var midiOutputName: String = ""   // empty = virtual source

    enum CodingKeys: String, CodingKey {
        case delayMs, interRoleDelayMs, prevVersionCommand, nextVersionCommand, roles, emailConfig, midiOutputName
    }

    init(delayMs: Int = 100,
         interRoleDelayMs: Int = 100,
         prevVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127),
         nextVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127),
         roles: [Role] = [], emailConfig: EmailConfig = EmailConfig(), midiOutputName: String = "") {
        self.delayMs = delayMs
        self.interRoleDelayMs = interRoleDelayMs
        self.prevVersionCommand = prevVersionCommand
        self.nextVersionCommand = nextVersionCommand
        self.roles = roles
        self.emailConfig = emailConfig
        self.midiOutputName = midiOutputName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delayMs            = (try? c.decodeIfPresent(Int.self,          forKey: .delayMs))            ?? 100
        interRoleDelayMs   = (try? c.decodeIfPresent(Int.self,          forKey: .interRoleDelayMs))   ?? 100
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
        let block: MIDINotifyBlock = { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved {
                DispatchQueue.main.async { self?.refreshDestinations() }
            }
        }
        let status = MIDIClientCreateWithBlock("MidiCastSwitcherClient" as CFString, &midiClient, block)
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
            migrateLegacySlots()
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

    /// One-time migration: if a track has no slotAssignments populated but the legacy
    /// slotOverrides + member.versionPosition data is present, build slotAssignments from it.
    /// Two phases so overrides win over defaults — otherwise a default versionPosition can
    /// stomp on another member's explicit override.
    private func migrateLegacySlots() {
        for r in config.roles.indices {
            let members = config.roles[r].members
            for t in config.roles[r].tracks.indices {
                var track = config.roles[r].tracks[t]
                track.syncSlotAssignmentsToVersionCount()
                let hasAnyAssignment = track.slotAssignments.contains(where: { $0 != nil })
                if !hasAnyAssignment && !members.isEmpty {
                    // Phase 1: explicit overrides claim their slots first.
                    for member in members {
                        if let slot = track.slotOverrides[member.id.uuidString],
                           slot >= 1 && slot <= track.versionCount {
                            track.slotAssignments[slot - 1] = member.id.uuidString
                        }
                    }
                    // Phase 2: members without an override fill their versionPosition slot,
                    // but only if it's still free (don't displace anyone).
                    for member in members where track.slotOverrides[member.id.uuidString] == nil {
                        let slot = member.versionPosition
                        if slot >= 1 && slot <= track.versionCount && track.slotAssignments[slot - 1] == nil {
                            track.slotAssignments[slot - 1] = member.id.uuidString
                        }
                    }
                }
                // Legacy data no longer needed after migration
                track.slotOverrides = [:]
                config.roles[r].tracks[t] = track
            }
        }
    }

    // Builds and fires the complete MIDI sequence for all selected cast members.
    // For each role's selected member, and for each track in that role:
    //   1. Send selectCommand to choose the track in Nuendo
    //   2. Send prevVersionCommand × (versionCount - 1) to reset to the first version
    //   3. Send nextVersionCommand × (versionPosition - 1) to navigate to the desired version
    func fireMidi() {
        // Schedule commands with absolute timestamps. Inserts an extra pause
        // (`interRoleDelayMs`) between role command-blocks, so Nuendo's MIDI Remote
        // gets breathing room between roles — without this, multi-role sends sometimes
        // dropped triggers under MIDI load.
        struct ScheduledCmd { let cmd: MidiCommand; let delayMs: Int }
        var schedule: [ScheduledCmd] = []
        var t = 0
        var trace: [String] = []

        for role in config.roles {
            guard let resolved = role.resolvePlaybackSource(allRoles: config.roles) else { continue }
            let variant = role.members.first(where: { $0.coverVariantOf == resolved.member.id })

            var roleHadCommands = false
            let borrowedCut = role.borrowedRoleIsCut(allRoles: config.roles)
            trace.append("ROLE \(role.name): resolved=\(resolved.member.name) isCover=\(resolved.isCover) variant=\(variant?.name ?? "—") borrowedRoleCut=\(borrowedCut)")

            for track in role.tracks {
                let principalSlot = track.slot(of: resolved.member.id)
                let variantSlot   = variant.flatMap { track.slot(of: $0.id) }
                // Prefer variant when: (a) a cover is selected, or (b) the linked "borrowed" role is cut.
                let preferVariant = resolved.isCover || borrowedCut
                let resolvedSlot: Int? = preferVariant
                    ? (variantSlot ?? principalSlot)
                    : (principalSlot ?? variantSlot)
                guard let targetSlot = resolvedSlot else {
                    trace.append("  \(track.name): SKIP (no slot for principal or variant)")
                    continue
                }
                roleHadCommands = true
                let resetSteps = max(0, track.versionCount - 1)
                let forwardSteps = max(0, targetSlot - 1)
                trace.append("  \(track.name): target=\(targetSlot) (principalSlot=\(principalSlot.map(String.init) ?? "—") variantSlot=\(variantSlot.map(String.init) ?? "—")) → select+prev×\(resetSteps)+next×\(forwardSteps)")

                // Send select TWICE to reinforce the track focus (Nuendo's MIDI Remote sometimes
                // misses the first select when under MIDI load — the redundancy is cheap insurance).
                schedule.append(.init(cmd: track.selectCommand, delayMs: t))
                t += config.delayMs
                schedule.append(.init(cmd: track.selectCommand, delayMs: t))
                t += config.delayMs
                for _ in 0..<resetSteps {
                    schedule.append(.init(cmd: config.prevVersionCommand, delayMs: t))
                    t += config.delayMs
                }
                // Re-affirm the track selection right before the forward navigation, in case
                // intermediate prev events nudged Nuendo's focus elsewhere.
                if forwardSteps > 0 {
                    schedule.append(.init(cmd: track.selectCommand, delayMs: t))
                    t += config.delayMs
                }
                for _ in 0..<forwardSteps {
                    schedule.append(.init(cmd: config.nextVersionCommand, delayMs: t))
                    t += config.delayMs
                }
            }

            // Extra pause between roles so Nuendo can settle before the next role's commands.
            if roleHadCommands && config.interRoleDelayMs > 0 {
                t += config.interRoleDelayMs
                trace.append("  ---- inter-role gap: \(config.interRoleDelayMs)ms ----")
            }
        }

        trace.append("---- MIDI schedule (\(schedule.count) commands, delay=\(config.delayMs)ms, interRole=\(config.interRoleDelayMs)ms) ----")
        for (i, entry) in schedule.enumerated() {
            let cmdStr: String
            switch entry.cmd.type {
            case .note: cmdStr = "Note  CH\(entry.cmd.channel) Nr\(entry.cmd.value1) vel\(entry.cmd.value2)"
            case .pc:   cmdStr = "PC    CH\(entry.cmd.channel) prog\(entry.cmd.value1)"
            case .cc:   cmdStr = "CC    CH\(entry.cmd.channel) ctrl\(entry.cmd.value1)=\(entry.cmd.value2)"
            }
            trace.append(String(format: "  [%2d] t=%5dms %@", i, entry.delayMs, cmdStr))
        }
        print(trace.joined(separator: "\n"))

        for entry in schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(entry.delayMs) / 1000.0) {
                self.send(command: entry.cmd)
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

// MARK: - Update Checker

/// Checks GitHub for the latest release tag and exposes whether an update is available.
/// Self-replace is blocked by App Sandbox, so the UI offers "Open release page" and
/// "Copy update command" actions instead of an in-app install.
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String? = nil
    @Published var isChecking = false
    @Published var lastError: String? = nil

    static let repoSlug = "omegajani/Midi-Cast-Switcher"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.compare(latest, currentVersion) > 0
    }

    var releasePageURL: URL {
        URL(string: "https://github.com/\(Self.repoSlug)/releases/latest")!
    }

    /// One-line shell command that downloads the latest release and replaces the installed
    /// app — without touching the user's config.json. Same as the README "Update" snippet.
    static var updateCommand: String {
        // Note: inside single quotes the shell takes characters literally, so we want '"' (just a
        // quote), not '\"' (backslash + quote — that's what tripped cut(1) before).
        """
        curl -sL "$(curl -sL https://api.github.com/repos/\(UpdateChecker.repoSlug)/releases/latest | grep browser_download_url | cut -d '"' -f 4)" -o /tmp/MCS.zip && unzip -qo /tmp/MCS.zip -d /tmp/MCS && rm -rf "/Applications/Midi Cast Switcher.app" && mv "/tmp/MCS/Midi Cast Switcher.app" /Applications/ && xattr -cr "/Applications/Midi Cast Switcher.app" && rm -rf /tmp/MCS /tmp/MCS.zip && open "/Applications/Midi Cast Switcher.app"
        """
    }

    func check() async {
        isChecking = true; lastError = nil
        defer { isChecking = false }
        let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases/latest")!
        do {
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                latestVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            } else {
                lastError = "Unerwartetes Antwortformat"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Semver-ish comparison. Returns -1, 0, +1 like strcmp.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let ai = i < pa.count ? pa[i] : 0
            let bi = i < pb.count ? pb[i] : 0
            if ai != bi { return ai < bi ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - App Entry Point

@main
struct MidiCastSwitcherApp: App {
    @StateObject private var midi = MidiController()
    @StateObject private var emailClient = IMAPClient()
    @StateObject private var updater = UpdateChecker()

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
            ConfigView(midi: midi, emailClient: emailClient, updater: updater)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 580)

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
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(role.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(width: 52, alignment: .leading)
                                    .lineLimit(1)

                                Picker("", selection: $role.selectedMemberId) {
                                    Text("—").tag(UUID?.none)
                                    // Only "real" principals — variants are hidden from the picker.
                                    ForEach(role.members
                                        .filter { $0.coverVariantOf == nil }
                                        .sorted { $0.versionPosition < $1.versionPosition }) { member in
                                        Text(member.name).tag(UUID?.some(member.id))
                                    }
                                    if !role.covers.isEmpty {
                                        Divider()
                                        ForEach(role.covers) { cover in
                                            Text("\(cover.name) (C)").tag(UUID?.some(cover.id))
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }

                            // Sub-label when a cover is selected: show the resolved playback source,
                            // preferring the variant name ("Sofia & Ballett") if one exists.
                            if let selId = role.selectedMemberId,
                               role.covers.contains(where: { $0.id == selId }),
                               let resolved = role.resolvePlaybackSource(allRoles: midi.config.roles) {
                                let displayName: String = {
                                    if let variant = role.members.first(where: { $0.coverVariantOf == resolved.member.id }) {
                                        return variant.name
                                    }
                                    return resolved.member.name
                                }()
                                HStack(spacing: 4) {
                                    Spacer().frame(width: 52)
                                    Text("↳ via \(displayName)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    if resolved.ambiguous {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(.orange)
                                            .help("Mehrere Principals abwesend — prüfen")
                                    }
                                }
                            }
                            // Sub-label when the borrowed role is cut: show which role's lines are included.
                            if role.borrowedRoleIsCut(allRoles: midi.config.roles),
                               let borrowedId = role.borrowsLinesFromRoleId,
                               let borrowedRole = midi.config.roles.first(where: { $0.id == borrowedId }) {
                                HStack(spacing: 4) {
                                    Spacer().frame(width: 52)
                                    Text("⊕ \(borrowedRole.name)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
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
    @ObservedObject var updater: UpdateChecker
    @State private var selectedRoleId: UUID? = nil
    @State private var emailPassword = ""
    @State private var copyConfirmed = false

    private let leftW: CGFloat  = 360
    private let minH:  CGFloat = 580

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
                                .help("Pause zwischen einzelnen MIDI-Commands")
                        }

                        HStack {
                            Text("Pause zw. Rollen:")
                                .font(.caption).foregroundColor(.secondary)
                            TextField("ms", value: $midi.config.interRoleDelayMs, formatter: NumberFormatter())
                                .frame(width: 54)
                                .textFieldStyle(.roundedBorder)
                            Text("ms").font(.caption).foregroundColor(.secondary)
                                .help("Zusätzliche Pause zwischen Command-Blöcken verschiedener Rollen, damit Nuendo bei Multi-Role-Sends nicht überlastet wird.")
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

                    Divider()

                    // Update section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 12))
                            Text("Update").font(.headline)
                        }

                        HStack(spacing: 8) {
                            Text("Aktuelle Version:")
                                .font(.caption).foregroundColor(.secondary)
                            Text(updater.currentVersion)
                                .font(.caption).foregroundColor(.primary)
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
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(updater.isChecking)
                        }

                        if let err = updater.lastError {
                            Text(err).font(.caption2).foregroundColor(.red)
                        } else if let latest = updater.latestVersion {
                            if updater.updateAvailable {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundColor(.accentColor)
                                    Text("Version \(latest) verfügbar")
                                        .font(.caption).foregroundColor(.accentColor)
                                }
                                HStack(spacing: 6) {
                                    Button("Auf GitHub öffnen") {
                                        NSWorkspace.shared.open(updater.releasePageURL)
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(UpdateChecker.updateCommand, forType: .string)
                                        copyConfirmed = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyConfirmed = false }
                                    } label: {
                                        Label(copyConfirmed ? "Kopiert!" : "Befehl kopieren",
                                              systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                }
                                Text("Befehl im Terminal einfügen — die Config bleibt erhalten.")
                                    .font(.caption2).foregroundColor(.secondary)
                            } else {
                                Text("Du hast die neueste Version.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .frame(width: leftW)
            .frame(maxHeight: .infinity)

            Divider()

            // Right panel: role detail
            Group {
                if let idx = midi.config.roles.firstIndex(where: { $0.id == selectedRoleId }) {
                    RoleDetailView(role: $midi.config.roles[idx], allRoles: midi.config.roles)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: minH, maxHeight: .infinity)
        .onChange(of: midi.config) { midi.saveConfig() }
    }
}

// MARK: - Role Detail View

struct RoleDetailView: View {
    @Binding var role: Role
    var allRoles: [Role] = []
    @State private var selectedMemberId: UUID? = nil

    private let trackW: CGFloat  = 380
    private let memberMinW: CGFloat = 260

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

    /// One row per slot in a track: shows "Slot N: [member dropdown]".
    /// Dropdown options are "—" (empty) plus all members of the role.
    /// Picking a member moves them to this slot and clears them from any other slot in this track.
    @ViewBuilder
    private func slotAssignmentRow(track: Binding<NuendoTrack>, slot: Int) -> some View {
        let idx = slot - 1
        let currentId: String? = (idx < track.wrappedValue.slotAssignments.count) ? track.wrappedValue.slotAssignments[idx] : nil
        HStack(spacing: 6) {
            Text("Slot \(slot)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .leading)
            Picker("", selection: Binding<String>(
                get: { currentId ?? "" },
                set: { newValue in
                    let memberUUID: UUID? = newValue.isEmpty ? nil : UUID(uuidString: newValue)
                    track.wrappedValue.setMember(memberUUID, atSlot: slot)
                }
            )) {
                Text("—").tag("")
                ForEach(role.members.sorted { $0.versionPosition < $1.versionPosition }) { member in
                    Text(member.name).tag(member.id.uuidString)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
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

                            HStack(spacing: 6) {
                                Text("Versionen:")
                                    .font(.caption).foregroundColor(.secondary)
                                Button {
                                    if $track.wrappedValue.versionCount > 1 {
                                        $track.wrappedValue.versionCount -= 1
                                        $track.wrappedValue.syncSlotAssignmentsToVersionCount()
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .disabled(track.versionCount <= 1)
                                Text("\(track.versionCount)")
                                    .frame(width: 22, alignment: .center)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Button {
                                    if $track.wrappedValue.versionCount < 32 {
                                        $track.wrappedValue.versionCount += 1
                                        $track.wrappedValue.syncSlotAssignmentsToVersionCount()
                                    }
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .disabled(track.versionCount >= 32)
                            }

                            Text("Auswahl-Befehl:")
                                .font(.caption).foregroundColor(.secondary)
                            MidiCommandRow(cmd: $track.selectCommand)

                            Divider().padding(.vertical, 2)
                            Text("Slots in diesem Kanal:")
                                .font(.caption).foregroundColor(.secondary)
                            ForEach(1...max(1, track.versionCount), id: \.self) { slot in
                                slotAssignmentRow(track: $track, slot: slot)
                            }
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
            .frame(width: trackW)
            .frame(maxHeight: .infinity)

            Divider()

            // Members column (fills remaining width)
            VStack(alignment: .leading, spacing: 0) {
                Text("Darsteller")
                    .font(.headline)
                    .padding([.horizontal, .top], 12)
                    .padding(.bottom, 4)

                // "Singt auch für" — when the linked role is "cut", this role uses Ballett-variants.
                HStack(spacing: 6) {
                    Text("Singt auch für:")
                        .font(.caption).foregroundColor(.secondary)
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
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                List(selection: $selectedMemberId) {
                    let sortedIndices = role.members.indices.sorted { role.members[$0].versionPosition < role.members[$1].versionPosition }
                    ForEach(sortedIndices, id: \.self) { idx in
                        let member = role.members[idx]
                        let isVariant = member.coverVariantOf != nil
                        let parentName = isVariant
                            ? (role.members.first(where: { $0.id == member.coverVariantOf })?.name ?? "?")
                            : ""
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                TextField("Name", text: Binding(
                                    get: { role.members[idx].name },
                                    set: { role.members[idx].name = $0 }
                                ))
                                .italic(isVariant)
                                Spacer()
                                // Reorder arrows only — no visible position number. ↑ moves up in
                                // the list, ↓ moves down. versionPosition just drives sort order.
                                Stepper("",
                                    onIncrement: { setPosition(for: member.id, to: max(1, member.versionPosition - 1)) },
                                    onDecrement: { setPosition(for: member.id, to: min(32, member.versionPosition + 1)) }
                                )
                                .labelsHidden()
                                .help("Reihenfolge im Live-Picker")
                            }
                            // Variant link, displayed as a clickable label opening a menu.
                            // - For Principals (no link): "als Ballett-Variante markieren"
                            // - For Variants: "↪ Variante von <Name>" — click to change/remove
                            let principalsForLink = role.members
                                .filter { $0.id != member.id && $0.coverVariantOf == nil }
                                .sorted { $0.versionPosition < $1.versionPosition }
                            Menu {
                                Button("— (kein Link)") {
                                    role.members[idx].coverVariantOf = nil
                                }
                                if !principalsForLink.isEmpty {
                                    Divider()
                                    ForEach(principalsForLink) { p in
                                        Button(p.name) {
                                            role.members[idx].coverVariantOf = p.id
                                        }
                                    }
                                }
                            } label: {
                                Text(isVariant ? "↪ Variante von \(parentName)" : "als Ballett-Variante markieren")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .padding(.leading, 2)
                        }
                        .padding(.vertical, 2)
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
                        // Auto-raise versionCount on all tracks to cover the new member count.
                        // Must also sync slotAssignments — otherwise the array stays shorter than
                        // versionCount and the slot picker crashes with "Index out of range".
                        let count = role.members.count
                        for i in role.tracks.indices where role.tracks[i].versionCount < count {
                            role.tracks[i].versionCount = count
                            role.tracks[i].syncSlotAssignmentsToVersionCount()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

                Divider()

                // Cover section
                Text("Cover")
                    .font(.headline)
                    .padding([.horizontal, .top], 12)
                    .padding(.bottom, 4)

                List {
                    ForEach($role.covers) { $cover in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $cover.name)
                                .font(.system(size: 12, weight: .medium))
                            HStack(spacing: 4) {
                                Text("Playback:")
                                    .font(.caption2).foregroundColor(.secondary)
                                Picker("", selection: Binding<String>(
                                    get: { cover.fixedSourceMemberId?.uuidString ?? "" },
                                    set: { newValue in
                                        cover.fixedSourceMemberId = newValue.isEmpty
                                            ? nil
                                            : UUID(uuidString: newValue)
                                    }
                                )) {
                                    Text("Auto (dynamisch)").tag("")
                                    // Only real principals, never variants
                                    ForEach(role.members
                                        .filter { $0.coverVariantOf == nil }
                                        .sorted { $0.versionPosition < $1.versionPosition }) { m in
                                        Text(m.name).tag(m.id.uuidString)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { role.covers.remove(atOffsets: $0) }
                }

                HStack {
                    Button("+ Cover") {
                        role.covers.append(Cover())
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)

                if let member = role.members.first(where: { $0.id == selectedMemberId }) {
                    Divider()
                    MidiSequencePreview(role: role, member: member)
                }
            }
            .frame(minWidth: memberMinW, maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(width: 50).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
            case .note:
                Text("Nr").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 50).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Text("Vel").font(.caption).foregroundColor(.secondary)
                TextField("127", value: $cmd.value2, formatter: midiFmt)
                    .frame(width: 50).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
            case .cc:
                Text("CC").font(.caption).foregroundColor(.secondary)
                TextField("0", value: $cmd.value1, formatter: midiFmt)
                    .frame(width: 50).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Text("Val").font(.caption).foregroundColor(.secondary)
                TextField("127", value: $cmd.value2, formatter: midiFmt)
                    .frame(width: 50).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
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
            // Match only against real Principals — Ballett-variants are auto-resolved in fireMidi.
            let match = role.members.first {
                $0.coverVariantOf == nil
                    && (($0.name.components(separatedBy: " ").first?.lowercased() ?? "") == first
                        || $0.name.lowercased().contains(first))
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
