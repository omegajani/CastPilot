//  Models.swift
//  CastPilot
//
//  Show data: roles, cast, covers, tracks, MIDI commands, config and show files.

import Foundation
import SwiftUI


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

