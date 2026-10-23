//  DigicoCheck.swift
//  CastPilot
//
//  Checks the DiGiCo Theatre players loaded on the console against today's cast.
//  The data comes from the DiGiCo-Bridge on the remote Mac; CastPilot only ever reads it.

import Foundation
import SwiftUI
import Combine

// MARK: - Bridge data

/// One console input channel as the bridge reports it (`GET /players`).
struct DigicoChannel: Codable, Equatable {
    var ch: Int
    var name: String
    var players: [String]
    /// The player loaded on the console right now; nil while the bridge can't tell.
    var loaded: String?
}

struct DigicoSnapshot: Codable, Equatable {
    /// How the bridge got the data ("file", "screen", "file+test").
    var source: String
    /// When the bridge last read the console, ISO 8601.
    var readAt: String
    var session: String
    var channels: [DigicoChannel]

    enum CodingKeys: String, CodingKey {
        case source, session, channels
        case readAt = "read_at"
    }

    func channel(_ ch: Int) -> DigicoChannel? { channels.first { $0.ch == ch } }

    var readDate: Date? { ISO8601DateFormatter().date(from: readAt) }

    /// All players listed on the given channels, in console order, without duplicates.
    func players(onChannels chs: [Int]) -> [String] {
        var seen = Set<String>()
        return chs.compactMap(channel).flatMap(\.players).filter { seen.insert(DigicoCheck.normalized($0)).inserted }
    }
}

// MARK: - Monitor

/// Polls the DiGiCo-Bridge every few seconds. It only sends GET requests — nothing in
/// CastPilot changes anything on the console.
final class DigicoMonitor: ObservableObject {
    static let pollInterval: Double = 2
    /// Older data than this counts as stale (bridge down or network gone).
    static let staleAfter: TimeInterval = 20

    @Published private(set) var snapshot: DigicoSnapshot?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    private(set) var bridgeAddress = ""
    private var pollTask: Task<Void, Never>?

    var isEnabled: Bool { !bridgeAddress.trimmingCharacters(in: .whitespaces).isEmpty }

    var isStale: Bool {
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) > Self.staleAfter
    }

    /// Starts polling `address`, or stops when it is empty. Calling it again with the same
    /// address keeps the running poll.
    func configure(address: String) {
        guard address != bridgeAddress || (pollTask == nil && isEnabled) else { return }
        bridgeAddress = address
        pollTask?.cancel()
        pollTask = nil
        snapshot = nil
        lastSuccess = nil
        lastError = nil
        guard isEnabled else { return }
        guard let url = Self.endpoint(for: address) else {
            lastError = "Ungültige Bridge-Adresse"
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(url)
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Accepts "10.10.100.20:8790", "http://host:8790" or a full ".../players" URL.
    static func endpoint(for address: String) -> URL? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), comps.host?.isEmpty == false else { return nil }
        if comps.path.isEmpty || comps.path == "/" { comps.path = "/players" }
        return comps.url
    }

    private func poll(_ url: URL) async {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                lastError = "Bridge antwortet mit HTTP \(http.statusCode)"
                return
            }
            snapshot = try JSONDecoder().decode(DigicoSnapshot.self, from: data)
            lastSuccess = Date()
            lastError = nil
        } catch is CancellationError {
        } catch let error as DecodingError {
            lastError = "Bridge liefert unbekanntes Format (\(error.localizedDescription))"
        } catch {
            lastError = "Bridge nicht erreichbar"
        }
    }
}

// MARK: - Check

enum DigicoStatus: Equatable {
    /// Every channel of the role has the expected player loaded.
    case ok(player: String)
    /// At least one channel has another player loaded: channel → loaded player.
    case mismatch(expected: String, loaded: [Int: String])
    /// The check can't decide (no data, player not found, load state unknown).
    case unknown(String)
    /// Nothing to check today (role not cast, or cut).
    case skipped(String)
}

enum DigicoCheck {
    /// Case-, accent- and whitespace-insensitive, so "Zoë" and "zoe  " compare equal.
    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The console player for a CastPilot name: an exact match, otherwise the single player
    /// whose name starts with it ("Mira" → "Mira Lang"). nil when none or ambiguous.
    static func matchPlayer(_ name: String, in players: [String]) -> String? {
        let n = normalized(name)
        guard !n.isEmpty else { return nil }
        if let exact = players.first(where: { normalized($0) == n }) { return exact }
        let prefixed = players.filter { normalized($0).hasPrefix(n + " ") }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// The player that has to be loaded for the role today, or why it can't be determined.
    static func expectedPlayer(for role: Role, allRoles: [Role], candidates: [String]) -> Result<String, CheckError> {
        guard let selId = role.selectedMemberId else { return .failure(.skip("nicht besetzt")) }
        if let member = role.members.first(where: { $0.id == selId }) {
            if normalized(member.name) == "cut" { return .failure(.skip("cut")) }
            return player(named: member.name, manual: member.digicoPlayer, candidates: candidates)
        }
        guard let cover = role.covers.first(where: { $0.id == selId }) else {
            return .failure(.skip("nicht besetzt"))
        }
        if let manual = cover.digicoPlayer, !manual.isEmpty { return .success(manual) }
        // Provisional rule: a cover gets the player whose playback CastPilot uses.
        guard let source = role.resolvePlaybackSource(allRoles: allRoles) else {
            return .failure(.unknown("Kein Playback für \(cover.name)"))
        }
        return player(named: source.member.name, manual: source.member.digicoPlayer, candidates: candidates)
    }

    private static func player(named name: String, manual: String?, candidates: [String]) -> Result<String, CheckError> {
        if let manual, !manual.isEmpty { return .success(manual) }
        if let auto = matchPlayer(name, in: candidates) { return .success(auto) }
        return .failure(.unknown("Kein eindeutiger Player für „\(name)“"))
    }

    enum CheckError: Error {
        case skip(String)
        case unknown(String)
    }

    /// nil when the role has no DiGiCo channels (not part of the check).
    static func status(of role: Role, allRoles: [Role], snapshot: DigicoSnapshot?) -> DigicoStatus? {
        guard !role.digicoChannels.isEmpty else { return nil }
        guard let snapshot else {
            // Still say "not cast" / "cut" without console data.
            if case .failure(.skip(let why)) = expectedPlayer(for: role, allRoles: allRoles, candidates: []) {
                return .skipped(why)
            }
            return .unknown("Keine Pultdaten")
        }
        var channels: [DigicoChannel] = []
        for ch in role.digicoChannels {
            guard let c = snapshot.channel(ch) else { return .unknown("Kanal \(ch) hat am Pult keine Player") }
            channels.append(c)
        }
        let expected: String
        switch expectedPlayer(for: role, allRoles: allRoles, candidates: snapshot.players(onChannels: role.digicoChannels)) {
        case .success(let p): expected = p
        case .failure(.skip(let why)): return .skipped(why)
        case .failure(.unknown(let why)): return .unknown(why)
        }
        var wrong: [Int: String] = [:]
        for c in channels {
            guard let loaded = c.loaded else { return .unknown("Pult meldet nicht, welcher Player geladen ist") }
            if normalized(loaded) != normalized(expected) { wrong[c.ch] = loaded }
        }
        return wrong.isEmpty ? .ok(player: expected) : .mismatch(expected: expected, loaded: wrong)
    }
}

// MARK: - Badge

/// Small status glyph for a role row in the live window.
struct DigicoBadge: View {
    let status: DigicoStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 14)
            .help(help)
    }

    private var symbol: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .mismatch: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        case .skipped: return "minus.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .ok: return .green
        case .mismatch: return .red
        case .unknown: return .orange
        case .skipped: return .secondary
        }
    }

    private var help: String {
        switch status {
        case .ok(let p): return "Pult: \(p) geladen"
        case .mismatch(let expected, let loaded):
            let chs = loaded.keys.sorted().map { "Ch \($0): \(loaded[$0] ?? "?")" }.joined(separator: ", ")
            return "Pult: erwartet \(expected) — geladen \(chs)"
        case .unknown(let why): return "Pult nicht prüfbar: \(why)"
        case .skipped(let why): return "Keine Pultprüfung (\(why))"
        }
    }
}
