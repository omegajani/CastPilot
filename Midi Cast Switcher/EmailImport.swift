//  EmailImport.swift
//  CastPilot
//
//  Cast import from the daily e-mail: keychain, IMAP client and import window.

import SwiftUI
import Foundation
import Network
import Security
import AppKit
import Combine

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
