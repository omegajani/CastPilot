import SwiftUI
import Combine
import CoreMIDI
import Foundation
import UniformTypeIdentifiers

#Preview {
    ContentView()
}
//whatisgoingonherebwekfast
#if canImport(AppKit)
import AppKit
class WindowSizeController {
    static func setWindowSize(width: CGFloat, height: CGFloat) {
        if let window = NSApplication.shared.windows.first {
            let screen = window.screen ?? NSScreen.main
            let maxSize = screen?.visibleFrame.size ?? CGSize(width: 1400, height: 1000)
            let w = min(width, maxSize.width)
            let h = min(height, maxSize.height)
            window.setContentSize(NSSize(width: w, height: h))
        }
    }
    static func setWindowMaxSize(width: CGFloat, height: CGFloat) {
        if let window = NSApplication.shared.windows.first {
            window.maxSize = NSSize(width: width, height: height)
        }
    }
    static func setWindowMinSize(width: CGFloat, height: CGFloat) {
        if let window = NSApplication.shared.windows.first {
            window.minSize = NSSize(width: width, height: height)
        }
    }
}
#endif

// MARK: - Models

enum MidiCommandType: String, Codable, CaseIterable, Identifiable {
    case note = "Note"
    case pc = "Program Change"
    case cc = "Control Change"
    var id: String { rawValue }
}

struct MidiCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neuer Befehl"
    var type: MidiCommandType = .pc
    var channel: Int = 1 // 1-16
    var value1: Int = 0 // note / param
    var value2: Int = 127 // velocity / value
}

struct CastMember: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neuer Darsteller"
    var commandIds: [UUID] = [] // Reference to library
}

struct Role: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Neue Rolle"
    var members: [CastMember] = []
    
    // UI state
    var selectedMemberId: UUID? = nil
}

struct AppConfig: Codable, Equatable {
    var delayMs: Int = 10
    var roles: [Role] = []
    var commandLibrary: [MidiCommand] = [] // Central library
}

// MARK: - XML Support
extension Array where Element == MidiCommand {
    func toXML() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MidiCommands>\n"
        for cmd in self {
            xml += "  <Command>\n"
            xml += "    <Name>\(cmd.name)</Name>\n"
            xml += "    <Type>\(cmd.type.rawValue)</Type>\n"
            xml += "    <Channel>\(cmd.channel)</Channel>\n"
            xml += "    <Value1>\(cmd.value1)</Value1>\n"
            xml += "    <Value2>\(cmd.value2)</Value2>\n"
            xml += "  </Command>\n"
        }
        xml += "</MidiCommands>"
        return xml
    }
    
    static func fromXML(_ xml: String) -> [MidiCommand] {
        var commands: [MidiCommand] = []
        let pattern = "(?s)<Command>(.*?)</Command>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, options: [], range: NSRange(location: 0, length: ns.length))
        
        for match in matches {
            let cmdStr = ns.substring(with: match.range(at: 1))
            var cmd = MidiCommand()
            
            let types = [
                ("<Name>(.*?)</Name>", 6, 7),
                ("<Type>(.*?)</Type>", 6, 7),
                ("<Channel>(.*?)</Channel>", 9, 10),
                ("<Value1>(.*?)</Value1>", 8, 9),
                ("<Value2>(.*?)</Value2>", 8, 9)
            ]
            
            for (p, _, _) in types {
                if let r = try? NSRegularExpression(pattern: p),
                   let m = r.firstMatch(in: cmdStr, range: NSRange(location: 0, length: (cmdStr as NSString).length)) {
                    let val = (cmdStr as NSString).substring(with: m.range(at: 1))
                    if p.contains("Name") { cmd.name = val }
                    else if p.contains("Type") { cmd.type = MidiCommandType(rawValue: val) ?? .pc }
                    else if p.contains("Channel") { cmd.channel = Int(val) ?? 1 }
                    else if p.contains("Value1") { cmd.value1 = Int(val) ?? 0 }
                    else if p.contains("Value2") { cmd.value2 = Int(val) ?? 0 }
                }
            }
            commands.append(cmd)
        }
        return commands
    }
}

// MARK: - MIDI Controller

class MidiController: ObservableObject {
    var midiClient: MIDIClientRef = 0
    var virtualSource: MIDIEndpointRef = 0
    
    @Published var config: AppConfig {
        didSet {
            saveConfig()
        }
    }
    private var lastFireTime: Date = .distantPast
    let configURL: URL
    
    init() {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("MidiCastTrigger")
        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        configURL = appDir.appendingPathComponent("config.json")
        
        // Initialize config
        self.config = AppConfig()
        
        loadConfig()
        setupMIDI()
    }
    
    func setupMIDI() {
        var status = MIDIClientCreate("MidiCastTriggerClient" as CFString, nil, nil, &midiClient)
        if status == noErr {
            status = MIDISourceCreate(midiClient, "MidiCastTrigger Source" as CFString, &virtualSource)
            if status != noErr {
                print("Error creating MIDI Source: \(status)")
            } else {
                print("MIDI Source Erstellt! Wählbar in Nuendo/Cubase unter 'MidiCastTrigger Source'")
            }
        }
    }
    
    func loadConfig() {
        // Default roles if none exist
        let defaultRoles = ["Aurora", "Nova", "Echo", "Luna", "Orion", "Iris"].map { Role(name: $0) }
        
        if let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = AppConfig(roles: defaultRoles)
        }
    }
    
    func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            try? encoded.write(to: configURL)
        }
    }
    
    func fireMidi() {
        let now = Date()
        guard now.timeIntervalSince(lastFireTime) >= 1.0 else { return }
        lastFireTime = now
        
        var allCommands: [MidiCommand] = []
        for role in config.roles {
            if let selId = role.selectedMemberId, let mem = role.members.first(where: { $0.id == selId }) {
                for cmdId in mem.commandIds {
                    if let libraryCmd = config.commandLibrary.first(where: { $0.id == cmdId }) {
                        allCommands.append(libraryCmd)
                    }
                }
            }
        }
        
        for (index, cmd) in allCommands.enumerated() {
            let delayTime = Double(index * config.delayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delayTime) {
                self.send(command: cmd)
            }
        }
    }
    
    private func send(command: MidiCommand) {
        let statusByte: UInt8
        switch command.type {
        case .note: statusByte = 0x90 + UInt8(command.channel - 1)
        case .pc: statusByte = 0xC0 + UInt8(command.channel - 1)
        case .cc: statusByte = 0xB0 + UInt8(command.channel - 1)
        }

        let byte1 = statusByte
        let byte2 = UInt8(command.value1 & 0x7F)
        let byte3 = UInt8(command.value2 & 0x7F)

        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        
        let bytes: [UInt8]
        if command.type == .pc {
            bytes = [byte1, byte2]
        } else {
            bytes = [byte1, byte2, byte3]
        }
        
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
        MIDIReceived(virtualSource, &packetList)
    }
}

// MARK: - Views (Modern & Clean)

struct ContentView: View {
    @StateObject var midiController = MidiController()
    @State private var selectedTab = 0 {
        didSet {
            updateWindowSizeForTab()
        }
    }
    @State private var showAbout = false
    @State private var showConfigSheet = false
    @State private var configSelectedSection = 0
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MidiCast Trigger")
                    .font(.title2)
                    .padding(.leading)
                Spacer()
                Button(action: { showAbout = true }) {
                    Image(systemName: "info.circle")
                }.buttonStyle(.plain)
                 .font(.headline)
                 .padding(.trailing)
            }
            .frame(height: 44)
            .background(.regularMaterial)
            Divider()

            TabView(selection: $selectedTab) {
                LiveTabView(midiController: midiController)
                    .tabItem {
                        Label("Live", systemImage: "bolt.fill")
                    }
                    .tag(0)
                ConfigTabView(midiController: midiController, onSectionChange: { newSection in
                    configSelectedSection = newSection
                    updateWindowSizeForTab()
                }, selectedSection: $configSelectedSection)
                    .tabItem {
                        Label("Konfiguration", systemImage: "slider.horizontal.3")
                    }
                    .tag(1)
            }
            .padding(.top, 0)
        }
        .sheet(isPresented: $showAbout) {
            AboutView(isPresented: $showAbout)
                .frame(width: 320, height: 420)
        }
        .sheet(isPresented: $showConfigSheet) {
            ConfigTabView(midiController: midiController)
                .frame(minWidth: 500, minHeight: 500)
        }
        .onAppear {
            updateWindowSizeForTab()
        }
        .onChange(of: selectedTab) { _ in
            updateWindowSizeForTab()
        }
        .onChange(of: configSelectedSection) { _ in
            if selectedTab == 1 {
                updateWindowSizeForTab()
            }
        }
    }
    
    private func updateWindowSizeForTab() {
        #if canImport(AppKit)
        switch selectedTab {
        case 0:
            WindowSizeController.setWindowSize(width: 370, height: 520)
            WindowSizeController.setWindowMaxSize(width: 500, height: 700)
        default:
            WindowSizeController.setWindowSize(width: 950, height: 600)
            WindowSizeController.setWindowMaxSize(width: 950, height: 700)
        }
        #endif
    }
}


struct LiveTabView: View {
    @ObservedObject var midiController: MidiController
    @State private var fireScale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($midiController.config.roles) { $role in
                        HStack(spacing: 0) {
                            Text(role.name)
                                .font(.headline)
                                .frame(width: 90, alignment: .leading)
                            Picker("", selection: $role.selectedMemberId) {
                                Text("-- Wählen --").tag(UUID?.none)
                                ForEach(role.members) { member in
                                    Text(member.name).tag(UUID?.some(member.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minWidth: .leastNonzeroMagnitude)
                        }
                        .padding(0)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            Button(action: {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                    fireScale = 0.93
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation { fireScale = 1.0 }
                }
                midiController.fireMidi()
            }) {
                Text("FIRE")
                    .font(.title2)
                    .frame(width: 200)
                    .padding(.vertical, 14)
                    .background(LinearGradient(gradient: Gradient(colors: [.red, .orange]), startPoint: .top, endPoint: .bottom))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                    .shadow(color: .red.opacity(0.2), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .scaleEffect(fireScale)
             .padding([.horizontal, .bottom])
        }
        .background(.regularMaterial)
    }
}

struct ConfigTabView: View {
    @ObservedObject var midiController: MidiController
    @Binding var selectedSection: Int
    var onSectionChange: ((Int) -> Void)? = nil

    init(midiController: MidiController, onSectionChange: ((Int) -> Void)? = nil, selectedSection: Binding<Int>? = nil) {
        self.midiController = midiController
        self.onSectionChange = onSectionChange
        if let sel = selectedSection {
            self._selectedSection = sel
        } else {
            self._selectedSection = .constant(0)
        }
    }

    var body: some View {
        VStack {
            Picker("", selection: $selectedSection) {
                Text("Rollen & Cast").tag(0)
                Text("MIDI-Bibliothek").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: selectedSection) { newValue in
                onSectionChange?(newValue)
            }
            if selectedSection == 0 {
                RolesConfigSection(midiController: midiController)
                    .frame(minWidth: 650)
                    .layoutPriority(1)
            } else {
                CommandLibrarySection(midiController: midiController)
                    .frame(minWidth: 800, maxWidth: 900)
                    .layoutPriority(1)
            }
        }
        .background(.ultraThinMaterial)
    }
}

struct RolesConfigSection: View {
    @ObservedObject var midiController: MidiController
    @State private var selectedRoleId: UUID? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rollen")
                    .font(.headline)
                List(selection: $selectedRoleId) {
                    ForEach($midiController.config.roles) { $role in
                        TextField("", text: $role.name)
                            .font(.body)
                            .tag(role.id)
                    }
                    .onDelete { indices in
                        midiController.config.roles.remove(atOffsets: indices)
                    }
                }
                .frame(minWidth: 250, maxWidth: 320, maxHeight: 180)
                .layoutPriority(1)
                HStack(spacing: 10) {
                    Button(action: {
                        midiController.config.roles.append(Role())
                    }) {
                        Label("Rolle +", systemImage: "plus")
                            .font(.headline)
                    }
                    Button(action: {
                        if let id = selectedRoleId {
                            midiController.config.roles.removeAll { $0.id == id }
                        }
                    }) {
                        Text("Löschen")
                            .font(.body)
                    }
                }
                // Neuer Button-Bereich: Backup Export/Import
                HStack(spacing: 12) {
                    Button("Backup Export") {
                        let savePanel = NSSavePanel()
                        savePanel.allowedContentTypes = [.json]
                        savePanel.nameFieldStringValue = "MidicastTriggerBackup.json"
                        if savePanel.runModal() == .OK, let url = savePanel.url {
                            do {
                                let data = try JSONEncoder().encode(midiController.config)
                                try data.write(to: url)
                            } catch {
                                print("Speichern fehlgeschlagen: \(error.localizedDescription)")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.body)
                    .help("Exportiert die aktuelle Konfiguration als JSON-Datei.")
                    Button("Backup Import") {
                        let openPanel = NSOpenPanel()
                        openPanel.allowedContentTypes = [.json]
                        openPanel.allowsMultipleSelection = false
                        if openPanel.runModal() == .OK, let url = openPanel.url {
                            do {
                                let data = try Data(contentsOf: url)
                                let importedConfig = try JSONDecoder().decode(AppConfig.self, from: data)
                                midiController.config = importedConfig
                            } catch {
                                print("Import fehlgeschlagen: \(error.localizedDescription)")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.body)
                    .help("Importiert eine Konfiguration aus einer JSON-Datei.")
                }
                .padding(.top, 8)
            }
            Divider()
            ScrollView {
                if let idx = midiController.config.roles.firstIndex(where: { $0.id == selectedRoleId }) {
                    RoleMemberDetail(role: $midiController.config.roles[idx], library: $midiController.config.commandLibrary)
                        .frame(minWidth: 400, maxWidth: .infinity)
                } else {
                    VStack {
                        Text("Bitte Rolle links auswählen")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
    }
}

struct CommandLibrarySection: View {
    @ObservedObject var midiController: MidiController

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MIDI-Befehlsbibliothek").font(.headline)
                    Spacer()
                    Button(action: {
                        midiController.config.commandLibrary.append(MidiCommand())
                    }) {
                        Label("Befehl +", systemImage: "plus")
                            .font(.headline)
                    }
                }
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(Array(midiController.config.commandLibrary.enumerated()), id: \ .element.id) { index, _ in
                            HStack(spacing: 8) {
                                TextField("Name", text: $midiController.config.commandLibrary[index].name)
                                    .font(.body)
                                    .frame(width: 160)
                                Picker("", selection: $midiController.config.commandLibrary[index].type) {
                                    ForEach(MidiCommandType.allCases) { t in Text(t.rawValue).tag(t) }
                                }
                                .frame(width: 120)
                                .pickerStyle(.menu)
                                TextField("CH", value: $midiController.config.commandLibrary[index].channel, formatter: NumberFormatter())
                                    .font(.body)
                                    .frame(width: 32)
                                    .multilineTextAlignment(.center)
                                if midiController.config.commandLibrary[index].type == .note {
                                    TextField("No", value: $midiController.config.commandLibrary[index].value1, formatter: NumberFormatter())
                                        .font(.body)
                                        .frame(width: 32)
                                        .multilineTextAlignment(.center)
                                    TextField("Vel", value: $midiController.config.commandLibrary[index].value2, formatter: NumberFormatter())
                                        .font(.body)
                                        .frame(width: 32)
                                        .multilineTextAlignment(.center)
                                } else if midiController.config.commandLibrary[index].type == .cc {
                                    TextField("CC", value: $midiController.config.commandLibrary[index].value1, formatter: NumberFormatter())
                                        .font(.body)
                                        .frame(width: 32)
                                        .multilineTextAlignment(.center)
                                    TextField("Val", value: $midiController.config.commandLibrary[index].value2, formatter: NumberFormatter())
                                        .font(.body)
                                        .frame(width: 32)
                                        .multilineTextAlignment(.center)
                                } else if midiController.config.commandLibrary[index].type == .pc {
                                    TextField("PC", value: $midiController.config.commandLibrary[index].value1, formatter: NumberFormatter())
                                        .font(.body)
                                        .frame(width: 32)
                                        .multilineTextAlignment(.center)
                                }
                                Button(action: {
                                    midiController.config.commandLibrary.remove(at: index)
                                }) {
                                    Image(systemName: "trash").foregroundColor(.red)
                                }
                            }
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                            .frame(maxWidth: 600, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .padding(.vertical, 4)
            }
            .padding()
            .frame(minWidth: 950, idealWidth: 1100, maxWidth: 1300)
        }
    }
}

struct RoleMemberDetail: View {
    @Binding var role: Role
    @Binding var library: [MidiCommand]
    @State private var selectedMemberId: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast für \(role.name)").font(.headline)
            List(selection: $selectedMemberId) {
                ForEach($role.members) { $member in
                    TextField("", text: $member.name)
                        .font(.body)
                        .tag(member.id)
                }
                .onDelete { indices in role.members.remove(atOffsets: indices) }
            }
            .frame(minHeight: 100)
            HStack {
                Button(action: {
                    role.members.append(CastMember())
                }) {
                    Label("Darsteller +", systemImage: "plus")
                        .font(.headline)
                }
            }
            if let mIdx = role.members.firstIndex(where: { $0.id == selectedMemberId }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MIDI-Befehle für \(role.members[mIdx].name)").font(.subheadline)
                        ForEach(Array(role.members[mIdx].commandIds.enumerated()), id: \.offset) { index, cmdId in
                            HStack(spacing: 6) {
                                Picker("", selection: $role.members[mIdx].commandIds[index]) {
                                    Text("-- Wählen --").tag(UUID())
                                    ForEach(library) { libCmd in
                                        Text(libCmd.name).tag(libCmd.id)
                                    }
                                }.pickerStyle(.menu).frame(width: 140)
                                Button(action: { role.members[mIdx].commandIds.remove(at: index) }) {
                                    Image(systemName: "trash").foregroundColor(.red)
                                }
                            }
                        }
                        Button(action: {
                            if let first = library.first {
                                role.members[mIdx].commandIds.append(first.id)
                            }
                        }) {
                            Label("Befehl +", systemImage: "plus")
                                .font(.headline)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}

struct AboutView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            if let imagePath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: imagePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .cornerRadius(14)
                    .shadow(radius: 5)
            } else {
                // Fallback Icon for missing AppIcon
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .foregroundColor(.accentColor)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(14)
                    .shadow(radius: 5)
            }
            
            Text("MCS")
                .font(.title)
            
            VStack(spacing: 4) {
                Text("Version 1.2")
                    .font(.body)
                Text("by János Tortorella")
                    .font(.body)
            }
            .foregroundColor(.secondary)
            
            Divider()
            
            VStack(spacing: 8) {
                Text("Entwickelt von")
                    .font(.body)
                    .foregroundColor(.secondary)
                
                Text("János Tortorella")
                    .font(.body)
            }
            
            Spacer()
            
            Button("Schließen") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
            .cornerRadius(12)
            .shadow(radius: 5)
            .font(.headline)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 320, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

@main
struct MidiCastTriggerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: .leastNonzeroMagnitude, minHeight: 520)
        }
    }
}

