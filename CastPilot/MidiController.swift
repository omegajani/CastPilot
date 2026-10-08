//  MidiController.swift
//  CastPilot
//
//  Virtual MIDI source, show open/save, and fireMidi() — the track-version switching.

import SwiftUI
import Combine
import CoreMIDI
import AppKit

// MARK: - MIDI Controller

struct MIDIDestinationInfo: Identifiable, Equatable {
    let id: MIDIEndpointRef
    let name: String
}

/// Feedback for the live window's send button. `selection` snapshots the cast that was sent,
/// so the UI can flag when the assignment changed afterwards.
enum SendStatus: Equatable {
    case idle
    case sending(commands: Int)
    case sent(at: Date, roles: Int, totalRoles: Int, selection: [UUID?])
    case nothingToSend
}

class MidiController: ObservableObject {
    var midiClient: MIDIClientRef = 0
    var virtualSource: MIDIEndpointRef = 0
    var outputPort: MIDIPortRef = 0

    /// Dedicated high-priority queue that walks the MIDI schedule off the main thread, so
    /// SwiftUI rendering can't jitter the timing. Serial → one sequence at a time.
    private let scheduleQueue = DispatchQueue(label: "com.castpilot.midischedule", qos: .userInteractive)

    @Published var config: AppConfig = AppConfig()
    @Published var availableDestinations: [MIDIDestinationInfo] = []
    @Published var savedSnapshot: ShowFile? = nil
    @Published var recentShows: [URL] = []
    @Published var sendStatus: SendStatus = .idle
    let configURL: URL
    let showsDir: URL

    init() {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("MidiCastSwitcher")
        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        configURL = appDir.appendingPathComponent("config.json")
        showsDir = appDir.appendingPathComponent("Shows")
        if !fm.fileExists(atPath: showsDir.path) {
            try? fm.createDirectory(at: showsDir, withIntermediateDirectories: true)
        }

        // One-time migration: earlier (sandboxed) builds stored config inside the app container.
        // Now that the sandbox is off, configURL points at ~/Library/Application Support/...
        // If the new location is empty but the old container has a config, copy it over so
        // existing users keep all their roles/tracks after updating to the unsandboxed build.
        if !fm.fileExists(atPath: configURL.path) {
            let legacy = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.janoslinde.Midi-Cast-Switcher/Data/Library/Application Support/MidiCastSwitcher/config.json")
            if fm.fileExists(atPath: legacy.path) {
                try? fm.copyItem(at: legacy, to: configURL)
            }
        }

        loadConfig()
        loadSavedSnapshot()
        loadRecentShows()
        setupMIDI()
        refreshDestinations()
    }

    // MARK: - Shows (documents)

    /// The open show file, if the current show has been saved to or opened from disk.
    var showFileURL: URL? { config.currentShowPath.map { URL(fileURLWithPath: $0) } }

    /// True when the show itself (roles, tracks, navigation — not today's cast) differs
    /// from what was last saved or opened.
    var isShowModified: Bool {
        guard let saved = savedSnapshot else { return true }
        return ShowFile(config: config) != saved
    }

    /// Unsaved changes, or never saved to a file — drives the "●" hints.
    var needsSave: Bool { showFileURL == nil || isShowModified }

    /// Opens a show file: roles and navigation come from the file, this machine's settings
    /// (MIDI output, e-mail, timing) stay. Today's cast is kept where the same role and
    /// performer exist in the opened show.
    func openShow(at url: URL) throws {
        var file = try JSONDecoder().decode(ShowFile.self, from: Data(contentsOf: url))
        guard !file.roles.isEmpty else { throw ShowFileError.noRoles }
        file.showName = url.deletingPathExtension().lastPathComponent
        let cast = Dictionary(config.roles.map { ($0.id, $0.selectedMemberId) }, uniquingKeysWith: { a, _ in a })
        var c = config
        c.showName = file.showName
        c.roles = file.roles.map { role in
            var r = role
            if let sel = cast[r.id] ?? nil,
               r.members.contains(where: { $0.id == sel }) || r.covers.contains(where: { $0.id == sel }) {
                r.selectedMemberId = sel
            }
            return r
        }
        c.prevVersionCommand = file.prevVersionCommand
        c.nextVersionCommand = file.nextVersionCommand
        c.currentShowPath = url.path
        config = c
        savedSnapshot = file
        noteRecentShow(url)
    }

    /// Writes the show — never machine settings or today's cast — to `url`.
    /// The file name becomes the show name, so "Speichern unter" also renames.
    func saveShow(to url: URL) throws {
        var file = ShowFile(config: config)
        file.showName = url.deletingPathExtension().lastPathComponent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
        config.showName = file.showName
        config.currentShowPath = url.path
        savedSnapshot = file
        noteRecentShow(url)
    }

    /// Replaces the show with the starter roles; machine settings and navigation stay.
    func newShow() {
        var c = config
        c.showName = "Unbenannt"
        c.roles = Self.defaultRoles()
        c.currentShowPath = nil
        config = c
        savedSnapshot = ShowFile(config: config)   // untouched new show: no "save changes?" prompt
    }

    /// Reads the open show file at launch, so unsaved changes survive a restart as such.
    private func loadSavedSnapshot() {
        guard let url = showFileURL,
              let data = try? Data(contentsOf: url),
              var file = try? JSONDecoder().decode(ShowFile.self, from: data) else {
            savedSnapshot = nil
            return
        }
        file.showName = url.deletingPathExtension().lastPathComponent
        savedSnapshot = file
    }

    // MARK: Recent shows

    private static let recentShowsKey = "recentShowPaths"

    private func loadRecentShows() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentShowsKey) ?? []
        recentShows = paths.map { URL(fileURLWithPath: $0) }
    }

    private func noteRecentShow(_ url: URL) {
        var list = recentShows.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        recentShows = Array(list.prefix(10))
        UserDefaults.standard.set(recentShows.map(\.path), forKey: Self.recentShowsKey)
    }

    func clearRecentShows() {
        recentShows = []
        UserDefaults.standard.removeObject(forKey: Self.recentShowsKey)
    }

    func setupMIDI() {
        let block: MIDINotifyBlock = { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved {
                DispatchQueue.main.async { self?.refreshDestinations() }
            }
        }
        let status = MIDIClientCreateWithBlock("CastPilotClient" as CFString, &midiClient, block)
        if status == noErr {
            MIDISourceCreate(midiClient, "CastPilot Source" as CFString, &virtualSource)
            MIDIOutputPortCreate(midiClient, "CastPilot Out" as CFString, &outputPort)
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
            self.config = AppConfig(roles: Self.defaultRoles())
        }
    }

    /// Starter roles for a fresh install and for "Neue Show".
    static func defaultRoles() -> [Role] {
        let defaultRoles = [
            ("Aurora",  ["Aurora HS",  "Aurora TS"]),
            ("Nova", ["Nova HS", "Nova TS"]),
            ("Echo",   ["Echo HS",   "Echo TS"]),
            ("Luna",  ["Luna HS",  "Luna TS"]),
            ("Orion",  ["Orion HS",  "Orion TS"]),
            ("Iris",  ["Iris HS",  "Iris TS"]),
        ]
        return defaultRoles.map { (roleName, trackNames) in
            Role(name: roleName, tracks: trackNames.map { NuendoTrack(name: $0) })
        }
    }

    func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            try? encoded.write(to: configURL)
        }
    }

    /// Normalizes legacy slot data in every role (see Role.migrateLegacySlots).
    private func migrateLegacySlots() {
        for r in config.roles.indices { config.roles[r].migrateLegacySlots() }
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
        var rolesSent = 0

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
            if roleHadCommands { rolesSent += 1 }
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

        // Deliver on a dedicated background thread, sending each packet immediately (timestamp 0
        // = now) at its precise moment via mach_wait_until. We do NOT hand CoreMIDI future
        // timestamps: the virtual source (MIDIReceived) ignores them and flushes the whole list
        // at once. Walking the schedule off the main thread keeps SwiftUI rendering from
        // jittering the timing — the reason events piled up before.
        let noteOffMs = 20   // short note-off, decoupled from delayMs so it never overlaps the next on

        // Flat (offsetMs, bytes) event list incl. note-offs, sorted by time.
        var events: [(off: Int, bytes: [UInt8])] = []
        for entry in schedule {
            events.append((entry.delayMs, bytes(for: entry.cmd)))
            if entry.cmd.type == .note {
                events.append((entry.delayMs + noteOffMs,
                               [0x80 + UInt8(entry.cmd.channel - 1), UInt8(entry.cmd.value1 & 0x7F), 0]))
            }
        }
        events.sort { $0.off < $1.off }
        guard !events.isEmpty else { sendStatus = .nothingToSend; return }

        // Resolve the destination ONCE here (on the main thread) and capture only primitives,
        // so the background closure never touches @Published state.
        let dest = selectedDestination
        let out = outputPort
        let vsrc = virtualSource
        let sentRoles = rolesSent
        let totalRoles = config.roles.count
        let selection = config.roles.map(\.selectedMemberId)
        sendStatus = .sending(commands: schedule.count)

        scheduleQueue.async {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let startTicks = mach_absolute_time()
            // nanoseconds → mach ticks:  ticks = ns * denom / numer
            func ticks(forMs ms: Int) -> UInt64 {
                let ns = UInt64(ms) * 1_000_000
                return startTicks &+ (ns &* UInt64(tb.denom) / UInt64(tb.numer))
            }
            for e in events {
                mach_wait_until(ticks(forMs: e.off))
                var pl = MIDIPacketList()
                var p = MIDIPacketListInit(&pl)
                p = MIDIPacketListAdd(&pl, 1024, p, 0, e.bytes.count, e.bytes)
                if let dest = dest {
                    MIDISend(out, dest, &pl)
                } else {
                    MIDIReceived(vsrc, &pl)
                }
            }
            // Report completion only after the last packet went out — outside the timing loop.
            DispatchQueue.main.async { [weak self] in
                self?.sendStatus = .sent(at: Date(), roles: sentRoles, totalRoles: totalRoles, selection: selection)
            }
        }
    }

    /// Builds the raw MIDI bytes for a command's "on" message (Note On / PC / CC).
    func bytes(for command: MidiCommand) -> [UInt8] {
        let statusByte: UInt8
        switch command.type {
        case .note: statusByte = 0x90 + UInt8(command.channel - 1)
        case .pc:   statusByte = 0xC0 + UInt8(command.channel - 1)
        case .cc:   statusByte = 0xB0 + UInt8(command.channel - 1)
        }
        let b2 = UInt8(command.value1 & 0x7F)
        let b3 = UInt8(command.value2 & 0x7F)
        return command.type == .pc ? [statusByte, b2] : [statusByte, b2, b3]
    }

    func send(command: MidiCommand) {
        let bytes = self.bytes(for: command)
        let b2 = UInt8(command.value1 & 0x7F)

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

