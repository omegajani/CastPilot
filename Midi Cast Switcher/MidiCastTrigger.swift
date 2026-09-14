import SwiftUI
import Combine
import CoreMIDI
import AppKit
import Network
import Security
import UniformTypeIdentifiers

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
    /// Name of the open show (= its file name). Shown in the live and editor windows.
    var showName: String = "Unbenannt"
    /// Path of the open .castpilot show file; nil until the show is saved to a file.
    var currentShowPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case delayMs, interRoleDelayMs, prevVersionCommand, nextVersionCommand, roles, emailConfig, midiOutputName, showName, currentShowPath
    }

    init(delayMs: Int = 100,
         interRoleDelayMs: Int = 100,
         prevVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127),
         nextVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127),
         roles: [Role] = [], emailConfig: EmailConfig = EmailConfig(), midiOutputName: String = "",
         showName: String = "Unbenannt", currentShowPath: String? = nil) {
        self.delayMs = delayMs
        self.interRoleDelayMs = interRoleDelayMs
        self.prevVersionCommand = prevVersionCommand
        self.nextVersionCommand = nextVersionCommand
        self.roles = roles
        self.emailConfig = emailConfig
        self.midiOutputName = midiOutputName
        self.showName = showName
        self.currentShowPath = currentShowPath
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
        showName           = (try? c.decodeIfPresent(String.self,       forKey: .showName))           ?? "Unbenannt"
        currentShowPath    = (try? c.decodeIfPresent(String.self,       forKey: .currentShowPath))    ?? nil
    }
}

// MARK: - Show file

/// Contents of a .castpilot show file: the show itself — never this machine's settings
/// (MIDI output, e-mail account, timing) or today's cast. The keys match AppConfig, so
/// show files written by older versions (a complete AppConfig) open unchanged.
struct ShowFile: Codable, Equatable {
    var formatVersion: Int = 2
    var showName: String = "Unbenannt"
    var roles: [Role] = []
    var prevVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127)
    var nextVersionCommand: MidiCommand = MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127)

    enum CodingKeys: String, CodingKey {
        case formatVersion, showName, roles, prevVersionCommand, nextVersionCommand
    }

    /// The show part of a config, with today's cast removed.
    init(config: AppConfig) {
        showName = config.showName
        roles = config.roles.map { var r = $0; r.selectedMemberId = nil; return r }
        prevVersionCommand = config.prevVersionCommand
        nextVersionCommand = config.nextVersionCommand
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion      = (try? c.decodeIfPresent(Int.self,         forKey: .formatVersion))      ?? 1
        showName           = (try? c.decodeIfPresent(String.self,      forKey: .showName))           ?? "Unbenannt"
        prevVersionCommand = (try? c.decodeIfPresent(MidiCommand.self, forKey: .prevVersionCommand)) ?? MidiCommand(type: .cc, channel: 1, value1: 1, value2: 127)
        nextVersionCommand = (try? c.decodeIfPresent(MidiCommand.self, forKey: .nextVersionCommand)) ?? MidiCommand(type: .cc, channel: 1, value1: 2, value2: 127)
        // Old files carry a cast and pre-1.3 slot data: drop the cast, normalize the slots.
        roles = ((try? c.decodeIfPresent([Role].self, forKey: .roles)) ?? []).map { role in
            var r = role
            r.selectedMemberId = nil
            r.migrateLegacySlots()
            return r
        }
    }

    /// Same show content, regardless of the file format version it was read from.
    static func == (a: ShowFile, b: ShowFile) -> Bool {
        a.showName == b.showName && a.roles == b.roles
            && a.prevVersionCommand == b.prevVersionCommand && a.nextVersionCommand == b.nextVersionCommand
    }
}

enum ShowFileError: LocalizedError {
    case noRoles
    var errorDescription: String? { "Die Datei enthält keine Rollen – ist das eine CastPilot-Show?" }
}

extension Role {
    /// Builds slotAssignments from legacy slotOverrides + member.versionPosition data when a
    /// track has none yet. Two phases so overrides win over defaults — otherwise a default
    /// versionPosition can stomp on another member's explicit override.
    mutating func migrateLegacySlots() {
        for t in tracks.indices {
            var track = tracks[t]
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
            tracks[t] = track
        }
    }
}

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

// MARK: - Update Checker

/// Checks GitHub for the latest release tag and exposes whether an update is available.
/// Since the App Sandbox is disabled, the app can download the release zip and replace
/// itself in place (via a detached relaunch script), so the UI offers a real 1-click update.
/// The "Copy update command" path is kept only as a fallback when the in-app install fails.
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String? = nil
    @Published var isChecking = false
    @Published var lastError: String? = nil
    @Published var isInstalling = false
    @Published var installError: String? = nil

    static let repoSlug = "omegajani/CastPilot"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.compare(latest, currentVersion) > 0
    }

    var releasePageURL: URL {
        // The releases list page — not /latest, which on GitHub resolves to the newest
        // NON-prerelease (v1.6 on main) and would hide the feature/covers prereleases.
        URL(string: "https://github.com/\(Self.repoSlug)/releases")!
    }

    /// Fetches the releases list (incl. prereleases) and returns the highest-semver release.
    /// We must NOT use /releases/latest — GitHub returns only the newest non-prerelease there,
    /// which is v1.6 on main, so the feature/covers prereleases would never be seen.
    private func bestRelease() async throws -> (tag: String, zipURL: URL?)? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases?per_page=30")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: (tag: String, dict: [String: Any])? = nil
        for r in arr where (r["draft"] as? Bool) != true {
            guard let raw = r["tag_name"] as? String else { continue }
            let v = raw.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            if best == nil || Self.compare(v, best!.tag) > 0 { best = (v, r) }
        }
        guard let b = best else { return nil }
        let assets = b.dict["assets"] as? [[String: Any]] ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }
        return (b.tag, zip.flatMap { URL(string: $0) })
    }

    /// One-line shell command that downloads the latest release and replaces the installed
    /// app — without touching the user's config.json. Same as the README "Update" snippet.
    static var updateCommand: String {
        // Note: inside single quotes the shell takes characters literally, so we want '"' (just a
        // quote), not '\"' (backslash + quote — that's what tripped cut(1) before).
        """
        curl -sL "$(curl -sL https://api.github.com/repos/\(UpdateChecker.repoSlug)/releases | grep browser_download_url | head -1 | cut -d '"' -f 4)" -o /tmp/MCS.zip && unzip -qo /tmp/MCS.zip -d /tmp/MCS && rm -rf "/Applications/Midi Cast Switcher.app" "/Applications/CastPilot.app" && mv "/tmp/MCS/CastPilot.app" /Applications/ && xattr -cr "/Applications/CastPilot.app" && rm -rf /tmp/MCS /tmp/MCS.zip && open "/Applications/CastPilot.app"
        """
    }

    func check() async {
        isChecking = true; lastError = nil
        defer { isChecking = false }
        do {
            if let best = try await bestRelease() {
                latestVersion = best.tag
            } else {
                lastError = "Keine Releases gefunden"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Downloads the latest release zip, unpacks it with ditto (which preserves the bundle's
    /// ad-hoc code signature), then hands off to a detached shell script that waits for this
    /// process to quit, swaps the app bundle in place, clears quarantine and relaunches.
    /// Requires the sandbox to be OFF (a sandboxed app — and any child it spawns — cannot
    /// write to /Applications).
    func downloadAndInstall() async {
        isInstalling = true; installError = nil
        defer { isInstalling = false }
        do {
            // 1. Resolve the .zip asset URL from the highest-semver release (incl. prereleases).
            guard let best = try await bestRelease(), let zipURL = best.zipURL
            else { installError = "Kein Zip im Release gefunden."; return }

            // 2. Download the zip. A programmatic download does NOT set the com.apple.quarantine
            //    xattr, so the relaunched app won't trip Gatekeeper.
            let (tmpZip, _) = try await URLSession.shared.download(from: zipURL)
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCSUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipDest = work.appendingPathComponent("MCS.zip")
            try FileManager.default.moveItem(at: tmpZip, to: zipDest)

            // 3. Unpack with ditto (better than unzip for .app bundles + signatures).
            let unpack = work.appendingPathComponent("unpacked")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", zipDest.path, unpack.path]
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                installError = "Entpacken fehlgeschlagen."; return
            }

            // 4. Locate the new .app (named CastPilot.app since the 2.0 rebrand).
            let newApp = unpack.appendingPathComponent("CastPilot.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                installError = "App im Zip nicht gefunden."; return
            }
            // Install next to where we currently run from (usually /Applications), always under
            // the new name. `oldBundle` is whatever we launched as — for users coming from the
            // pre-rebrand build that's "Midi Cast Switcher.app", which we remove.
            let oldBundle = Bundle.main.bundlePath
            let installDir = (oldBundle as NSString).deletingLastPathComponent
            let finalTarget = (installDir as NSString).appendingPathComponent("CastPilot.app")

            // 5. Write a relaunch script and launch it detached. It waits for our PID to exit,
            //    removes the old bundle, moves the new one into place, clears quarantine, reopens.
            let script = """
            #!/bin/sh
            APP_PID="$1"; NEW="$2"; OLD="$3"; FINAL="$4"
            while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
            sleep 0.3
            rm -rf "$OLD"
            rm -rf "$FINAL"
            mv "$NEW" "$FINAL"
            xattr -cr "$FINAL"
            open "$FINAL"
            """
            let scriptURL = work.appendingPathComponent("relaunch.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path,
                              String(ProcessInfo.processInfo.processIdentifier),
                              newApp.path, oldBundle, finalTarget]
            try task.run()

            // 6. Quit so the detached script can replace the running bundle.
            NSApp.terminate(nil)
        } catch {
            installError = error.localizedDescription
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

// MARK: - Shared UI Building Blocks

/// One place for spacing, label width and type used across the editor and settings windows.
enum UI {
    static let pad: CGFloat = 12
    static let labelWidth: CGFloat = 96
    static let itemTitle = Font.system(size: 13, weight: .semibold)
    static let coverTint = Color.orange
    /// Plain integer formatter — no thousands separator (ports, milliseconds).
    static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.usesGroupingSeparator = false
        f.allowsFloats = false
        return f
    }()
}

/// Column / section title with uniform spacing, so headers line up across columns.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UI.pad)
            .padding(.top, UI.pad)
            .padding(.bottom, 6)
    }
}

/// Label on the left (no colon), control on the right. Pass `labelWidth: nil` for a natural-width label.
struct FieldRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat?
    let content: Content

    init(_ label: String, labelWidth: CGFloat? = UI.labelWidth, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
    }
}

/// macOS-style +/− bar under a list. "−" removes the selected row.
struct AddRemoveBar: View {
    let addHelp: String
    let removeHelp: String
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onAdd) {
                Image(systemName: "plus").frame(width: 22, height: 18)
            }
            .help(addHelp)
            Button(action: onRemove) {
                Image(systemName: "minus").frame(width: 22, height: 18)
            }
            .disabled(!canRemove)
            .help(removeHelp)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Small orange "Cover" tag, used wherever a cover is selected.
struct CoverBadge: View {
    var body: some View {
        Text("Cover")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(UI.coverTint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(UI.coverTint.opacity(0.18)))
    }
}

/// Ballett variants are marked with "↪" wherever members are listed (menus can't show italics).
func memberDisplayName(_ member: CastMember) -> String {
    member.coverVariantOf == nil ? member.name : "↪ \(member.name)"
}

// MARK: - Live View

struct LiveView: View {
    @ObservedObject var midi: MidiController
    @ObservedObject var emailClient: IMAPClient
    @State private var fireScale: CGFloat = 1.0
    @Environment(\.openWindow) private var openWindow
    @AppStorage(LiveWindow.onTopKey) private var liveWindowOnTop = true

    private let nameW: CGFloat = 52

    private var hasAssignment: Bool {
        midi.config.roles.contains { $0.selectedMemberId != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Role rows
            ScrollView {
                VStack(spacing: 4) {
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(r.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: nameW, alignment: .leading)
                    .lineLimit(1)
                castMenu(role)
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
        }
        .padding(10)
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
        case .noEmailFound:            return "Keine E-Mail mit „Cast Information“ im Betreff gefunden."
        case .fetchFailed:             return "E-Mail-Inhalt konnte nicht geladen werden."
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
                    Text("Besetzung aus E-Mail")
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
                Text("Original-E-Mail").font(.caption.bold()).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        if imap.rawEmailText.isEmpty {
                            Text("Noch keine E-Mail geladen.")
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
                             ? "E-Mail abrufen, um die Besetzung zu importieren."
                             : "Keine Rollen erkannt.\nStichwörter der Rollen im Show-Editor prüfen.")
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
                                        ForEach(role.members) { m in Text(memberDisplayName(m)).tag(UUID?.some(m.id)) }
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
