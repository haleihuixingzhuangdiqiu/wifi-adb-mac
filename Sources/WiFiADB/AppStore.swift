import Foundation
import SwiftUI
import AppKit
import ADBCore

enum Page: String, CaseIterable, Identifiable {
    case devices = "我的设备", discovery = "发现设备", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .devices: return "iphone.gen3.radiowaves.left.and.right"; case .discovery: return "dot.radiowaves.left.and.right"; case .settings: return "slider.horizontal.3" }
    }
    var subtitle: String {
        switch self {
        case .devices: return "查看所有当前连接，保存常用设备后可一键重连。"
        case .discovery: return "查看局域网服务与 adb 当前的设备状态。"
        case .settings: return "使用本机 adb，连接过程由你掌控。"
        }
    }
}

struct AddDeviceDraft: Identifiable {
    let id = UUID()
    var host = ""
    var port = ""
}

@MainActor
final class AppStore: ObservableObject {
    @Published var page: Page = .devices
    @Published private(set) var devices: [SavedDevice] = []
    @Published private(set) var snapshot = DiscoverySnapshot()
    @Published private(set) var verified: [String: String] = [:]
    @Published private(set) var rejected = Set<String>()
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published private(set) var activeDeviceID: UUID?
    @Published private(set) var adbURL: URL?
    @Published private(set) var adbVersion: String?
    @Published private(set) var lastRefresh: Date?
    @Published var notice: String?
    @Published private(set) var storageError: String?
    @Published var addDraft: AddDeviceDraft?
    @Published var showHelp = false
    @Published var renameDevice: SavedDevice?
    @Published var forgetDevice: SavedDevice?

    let storage = DeviceStorage()
    let pathOverride = ProcessInfo.processInfo.environment["WIFIADB_ADB_PATH"] != nil
    private var coordinator: ConnectionCoordinator?
    private var didLoadInitialState = false
    private var storageWritable = true
    private var settingsWritable = true
    private struct Settings: Codable { let adbPath: String }

    init() {
        do { devices = try storage.load() }
        catch { storageError = ADBError.storageRead.localizedDescription; storageWritable = false }
        adbURL = ADBLocation.detect()
        let settingsURL = storage.directory.appendingPathComponent("settings.json")
        if !pathOverride, FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
                adbURL = URL(fileURLWithPath: settings.adbPath)
            } catch {
                settingsWritable = false
                notice = "无法读取 adb 路径设置，已保留原文件并尝试自动检测。请检查 settings.json。"
            }
        }
        configureClient()
    }

    var adbAvailable: Bool { adbURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }
    var connectedCount: Int {
        Set(snapshot.transports.filter { $0.isWireless && $0.state == .device }
            .map { verified[$0.id].map { "serial:\($0)" } ?? "transport:\($0.id)" }).count
    }
    var connectServices: [MDNSService] { snapshot.services.filter(\.isConnect) }
    var canSave: Bool { storageWritable }
    func status(_ device: SavedDevice) -> SavedConnectionStatus { .resolve(device, snapshot: snapshot, verified: verified, rejected: rejected) }

    private func configureClient() {
        coordinator = adbURL.map { ConnectionCoordinator(client: ADBClient(executable: $0)) }
        adbVersion = nil; snapshot = DiscoverySnapshot(); verified = [:]; rejected = []; lastRefresh = nil
    }
    func loadInitialState() async {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        await refresh()
    }
    private func begin(_ label: String, device: UUID? = nil) -> ConnectionCoordinator? {
        guard !busy else { return nil }
        guard adbAvailable, let coordinator else { notice = ADBError.unavailable.localizedDescription; return nil }
        busy = true; activity = label; activeDeviceID = device
        return coordinator
    }
    private func end() { busy = false; activity = ""; activeDeviceID = nil }
    private func message(_ error: Error) -> String { (error as? ADBError ?? .commandFailed).localizedDescription }
    private func accept(_ result: ConnectionResult) async throws {
        var updated = devices
        if let index = updated.firstIndex(where: { $0.hardwareSerial == result.device.hardwareSerial }) {
            updated[index].lastEndpoint = result.device.lastEndpoint
            updated[index].lastConnected = result.device.lastConnected
            if let identity = result.device.mdnsIdentity { updated[index].mdnsIdentity = identity }
        } else { updated.insert(result.device, at: 0) }
        snapshot = result.snapshot
        if let coordinator {
            verified = await coordinator.verifiedSerials()
            rejected = await coordinator.rejectedTransports()
        }
        try persist(updated)
        lastRefresh = Date()
    }
    private func persist(_ updated: [SavedDevice]) throws {
        guard storageWritable else { throw ADBError.storageRead }
        try storage.save(updated)
        devices = updated
    }

    func refresh() async {
        guard let coordinator = begin("正在刷新") else { return }
        defer { end() }
        do {
            if adbVersion == nil { adbVersion = try await coordinator.version() }
            snapshot = try await coordinator.refresh()
            verified = await coordinator.verifiedSerials()
            rejected = await coordinator.rejectedTransports()
            lastRefresh = Date()
            notice = nil
        } catch {
            // Never retain an old green status after adb becomes unreachable.
            snapshot = DiscoverySnapshot(discoveryAvailable: false); verified = [:]; rejected = []
            notice = message(error)
        }
    }
    func reconnect(_ device: SavedDevice) async {
        guard let coordinator = begin("正在验证并重连", device: device.id) else { return }
        defer { end() }
        do {
            let result = try await coordinator.reconnect(device)
            try await accept(result)
            notice = nil
        } catch {
            notice = message(error)
            await refreshAfterAction(coordinator)
        }
    }
    /// Returns nil on complete success. Pairing success is reported separately so the
    /// sheet can stay open for connection-port correction without repeating pairing.
    func add(host: String, port: String, name: String, pairPort: String?, code: String,
             didPair: @MainActor () -> Void) async -> String? {
        guard storageWritable else { return ADBError.storageRead.localizedDescription }
        let endpoint: Endpoint, pairing: Endpoint?
        do {
            endpoint = try Endpoint(host: host, portText: port)
            pairing = try pairPort.map { try Endpoint(host: host, portText: $0) }
            if pairing != nil, !(code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) { throw ADBError.invalidCode }
        } catch { return message(error) }
        guard let coordinator = begin(pairing == nil ? "正在连接并验证" : "正在配对") else { return notice ?? ADBError.busy.localizedDescription }
        defer { end() }
        var paired = false
        do {
            if let pairing {
                try await coordinator.pair(pairing, code: code)
                paired = true; didPair()
                activity = "正在连接并验证"
            }
            let result = try await coordinator.connect(endpoint, name: name)
            try await accept(result)
            notice = nil
            return nil
        } catch {
            await refreshAfterAction(coordinator)
            return (paired ? "配对成功，请输入无线调试主页的连接端口。\n" : "") + message(error)
        }
    }
    func save(_ transport: ADBTransport) async {
        guard storageWritable else { notice = ADBError.storageRead.localizedDescription; return }
        guard let coordinator = begin("正在验证并保存") else { return }
        defer { end() }
        do {
            try await accept(coordinator.saveConnected(transport, name: transport.displayName))
            notice = nil
        } catch {
            notice = message(error)
            await refreshAfterAction(coordinator)
        }
    }
    func disconnect(_ transport: ADBTransport) async {
        guard let coordinator = begin("正在断开所选设备") else { return }
        defer { end() }
        do {
            try await coordinator.disconnect(transport)
            let refreshed = await refreshAfterAction(coordinator)
            if !refreshed {
                notice = "断开请求已发送，暂时无法核实最新连接状态。"
            } else if snapshot.transports.contains(where: { $0.id == transport.id }) {
                notice = "断开请求已发送，当前连接仍可见；ADB 可能已自动重新连接。"
            } else {
                notice = nil
            }
        } catch {
            notice = message(error)
            await refreshAfterAction(coordinator)
        }
    }
    func connectDiscovered(_ service: MDNSService) async {
        let error = await add(host: service.endpoint.host, port: String(service.endpoint.port), name: "", pairPort: nil, code: "", didPair: {})
        if let error { notice = error }
        else { page = .devices }
    }
    @discardableResult
    private func refreshAfterAction(_ coordinator: ConnectionCoordinator) async -> Bool {
        do {
            snapshot = try await coordinator.refresh()
            verified = await coordinator.verifiedSerials(); rejected = await coordinator.rejectedTransports(); lastRefresh = Date()
            return true
        } catch { snapshot = DiscoverySnapshot(discoveryAvailable: false); verified = [:]; rejected = []; return false }
    }
    func rename(_ device: SavedDevice, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120, let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        var updated = devices; updated[index].name = clean
        do { try persist(updated) } catch { notice = message(error) }
    }
    func forget(_ device: SavedDevice) {
        do { try persist(devices.filter { $0.id != device.id }) }
        catch { notice = message(error) }
    }
    func selectADB() {
        guard !busy, !pathOverride else { return }
        let panel = NSOpenPanel()
        panel.title = "选择本机 adb"; panel.message = "请选择 Android SDK platform-tools 文件夹中的 adb 可执行文件。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path), !url.hasDirectoryPath else { notice = ADBError.unavailable.localizedDescription; return }
        guard settingsWritable else { notice = "路径设置文件损坏，原文件已保留。请修复 settings.json 后重新启动。"; return }
        do {
            try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Settings(adbPath: url.path)).write(to: storage.directory.appendingPathComponent("settings.json"), options: .atomic)
            adbURL = url; configureClient(); notice = nil
            Task { await refresh() }
        } catch { notice = ADBError.storageWrite.localizedDescription }
    }
}
