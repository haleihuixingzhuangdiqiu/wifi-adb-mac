import Foundation

public struct ADBClient: Sendable {
    public let executable: URL
    public let executor: any ProcessExecuting
    public init(executable: URL, executor: any ProcessExecuting = ProcessRunner()) { self.executable = executable; self.executor = executor }

    private func command(_ arguments: [String], timeout: TimeInterval = 8) async throws -> String {
        let result = try await executor.run(ProcessRequest(executable: executable, arguments: arguments, timeout: timeout))
        guard result.status == 0 else { throw ADBError.commandFailed }
        return result.stdout
    }
    public func version() async throws -> String {
        let output = try await command(["version"])
        // Return only a version token, never arbitrary executable output.
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("Android Debug Bridge version ") {
            let version = String(line.dropFirst("Android Debug Bridge version ".count))
            if !version.isEmpty && version.count < 40 && version.allSatisfy({ $0.isNumber || $0 == "." }) { return version }
        }
        throw ADBError.commandFailed
    }
    public func devices() async throws -> [ADBTransport] { ADBParser.devices(try await command(["devices", "-l"])) }
    public func services() async throws -> [MDNSService] { ADBParser.mdns(try await command(["mdns", "services"], timeout: 2)) }
    public func snapshot() async throws -> DiscoverySnapshot {
        let transports = try await devices()
        do { return DiscoverySnapshot(transports: transports, services: try await services()) }
        catch is CancellationError { throw CancellationError() }
        catch { return DiscoverySnapshot(transports: transports, discoveryAvailable: false) }
    }
    public func connect(_ endpoint: Endpoint) async throws { _ = try await command(["connect", endpoint.description], timeout: 15) }
    public func disconnect(_ transport: ADBTransport) async throws {
        guard ADBParser.validTransportID(transport.id), transport.isWireless, !transport.isEmulator else { throw ADBError.notConnected }
        _ = try await command(["disconnect", transport.id], timeout: 8)
    }
    public func serial(of transportID: String) async throws -> String {
        guard ADBParser.validTransportID(transportID) else { throw ADBError.identityUnavailable }
        let output = try await command(["-s", transportID, "shell", "getprop", "ro.serialno"], timeout: 2)
        guard let serial = ADBParser.hardwareSerial(output) else { throw ADBError.identityUnavailable }
        return serial
    }
    public func pair(_ endpoint: Endpoint, code: String) async throws {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ADBError.invalidCode }
        do {
            let result = try await executor.run(ProcessRequest(executable: executable, arguments: ["pair", endpoint.description],
                                                               standardInput: Data((code + "\n").utf8), timeout: 30))
            // Some adb releases return exit zero for protocol failures. Never expose either stream.
            guard result.status == 0, result.stdout.contains("Successfully paired to"),
                  !result.stdout.lowercased().contains("failed") else { throw ADBError.pairingFailed }
        } catch { throw ADBError.pairingFailed }
    }
}

public struct ConnectionResult: Sendable {
    public let device: SavedDevice
    public let transportID: String
    public let snapshot: DiscoverySnapshot
}

/// Serializes user actions and refreshes. The UI additionally disables actions while busy.
public actor ConnectionCoordinator {
    private let client: ADBClient
    private var busy = false
    private var verified: [String: String] = [:]
    private var rejected = Set<String>()
    public init(client: ADBClient) { self.client = client }
    private func begin() throws { guard !busy else { throw ADBError.busy }; busy = true }

    public func refresh() async throws -> DiscoverySnapshot {
        try begin(); defer { busy = false }
        let snapshot = try await freshSnapshot()
        try await verify(onlineWireless(in: snapshot))
        return snapshot
    }
    public func version() async throws -> String {
        try begin(); defer { busy = false }
        return try await client.version()
    }
    public func verifiedSerials() -> [String: String] { verified }
    public func rejectedTransports() -> Set<String> { rejected }

    public func reconnect(_ saved: SavedDevice) async throws -> ConnectionResult {
        try begin(); defer { busy = false }
        let before = try await freshSnapshot()
        let online = onlineWireless(in: before)
        try await verify(online)
        // A verified live transport does not require discovery or a new connect command.
        let matching = online.filter { verified[$0.id] == saved.hardwareSerial }
            .sorted { $0.endpoint != nil && $1.endpoint == nil }
        for target in matching {
            let endpoints = Set(before.services.filter { $0.isConnect && $0.matches(transport: target) }.map(\.endpoint))
            guard target.endpoint != nil || endpoints.count <= 1 else { throw ADBError.ambiguous }
            guard let endpoint = target.endpoint ?? endpoints.first else {
                var device = saved
                device.lastConnected = Date()
                // lastEndpoint is historical; do not fabricate a current address.
                return ConnectionResult(device: device, transportID: target.id, snapshot: before)
            }
            let aliases = candidates(for: endpoint, in: before)
            try requireIdentity(of: aliases, expected: saved.hardwareSerial)
            return result(for: target, endpoint: endpoint, serial: saved.hardwareSerial, expected: saved, name: saved.name, snapshot: before)
        }
        let endpoint = try ReconnectResolver.endpoint(for: saved, services: before.services)
        return try await connectAndVerify(endpoint, expected: saved, name: saved.name, before: before)
    }
    public func connect(_ endpoint: Endpoint, name: String) async throws -> ConnectionResult {
        try begin(); defer { busy = false }
        let before = try await freshSnapshot()
        return try await connectAndVerify(endpoint, expected: nil, name: name, before: before)
    }
    public func pair(_ endpoint: Endpoint, code: String) async throws {
        try begin(); defer { busy = false }
        try await client.pair(endpoint, code: code)
    }
    public func saveConnected(_ transport: ADBTransport, name: String) async throws -> ConnectionResult {
        try begin(); defer { busy = false }
        let snapshot = try await freshSnapshot()
        try await verify(onlineWireless(in: snapshot))
        guard transport.isWireless, !transport.isEmulator,
              let live = onlineWireless(in: snapshot).first(where: { $0.id == transport.id }) else { throw ADBError.notConnected }
        let services = snapshot.services.filter { $0.isConnect && $0.matches(transport: live) }
        let endpoints = Set(services.map(\.endpoint))
        guard live.endpoint != nil || endpoints.count <= 1 else { throw ADBError.ambiguous }
        guard let endpoint = live.endpoint ?? endpoints.first else { throw ADBError.addressRequired }
        let aliases = candidates(for: endpoint, in: snapshot)
        let serial = try requireIdentity(of: aliases)
        let device = SavedDevice(name: normalizedName(name, fallback: live.displayName), hardwareSerial: serial,
                                 mdnsIdentity: services.count == 1 ? services[0].name : nil, lastEndpoint: endpoint)
        return ConnectionResult(device: device, transportID: live.id, snapshot: snapshot)
    }
    public func disconnect(_ transport: ADBTransport) async throws {
        try begin(); defer { busy = false }
        verified.removeAll(); rejected.removeAll()
        // A current transport list is sufficient; discovery must not delay a click.
        let transports = try await client.devices()
        guard ADBParser.validTransportID(transport.id), transport.isWireless, !transport.isEmulator,
              let live = transports.first(where: { $0.id == transport.id && $0.isWireless && !$0.isEmulator }) else {
            throw ADBError.notConnected
        }
        try await client.disconnect(live)
    }

    // Invalidate before I/O, including failed snapshots. Textual endpoint reuse is not identity.
    private func freshSnapshot() async throws -> DiscoverySnapshot {
        verified.removeAll()
        rejected.removeAll()
        return try await client.snapshot()
    }
    private func onlineWireless(in snapshot: DiscoverySnapshot) -> [ADBTransport] {
        snapshot.transports.filter { $0.state == .device && $0.isWireless && !$0.isEmulator }
    }
    private func candidates(for endpoint: Endpoint, in snapshot: DiscoverySnapshot) -> [ADBTransport] {
        let services = snapshot.services.filter { $0.isConnect && $0.endpoint == endpoint }
        return onlineWireless(in: snapshot).filter { transport in
            transport.endpoint == endpoint || services.contains(where: { $0.matches(transport: transport) })
        }
    }
    // Sliding window: at most four two-second queries, never shells on USB or emulators.
    private func verify(_ transports: [ADBTransport]) async throws {
        let client = self.client
        var ids = Array(Set(transports.filter { $0.state == .device && $0.isWireless && !$0.isEmulator }.map(\.id))).sorted().makeIterator()
        let identities = try await withThrowingTaskGroup(of: (String, String?).self) { group in
            func enqueue(_ id: String) {
                group.addTask {
                    try Task.checkCancellation()
                    do { return (id, try await client.serial(of: id)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (id, nil) }
                }
            }
            for _ in 0..<4 { if let id = ids.next() { enqueue(id) } }
            var identities: [String: String] = [:]
            while let (id, serial) = try await group.next() {
                if let serial { identities[id] = serial }
                if let id = ids.next() { enqueue(id) }
            }
            try Task.checkCancellation()
            return identities
        }
        verified = identities
        rejected = Set(transports.map(\.id)).subtracting(identities.keys)
    }
    @discardableResult
    private func requireIdentity(of aliases: [ADBTransport], expected: String? = nil) throws -> String {
        guard !aliases.isEmpty else { throw ADBError.notConnected }
        guard aliases.allSatisfy({ verified[$0.id] != nil }) else {
            rejected.formUnion(aliases.map(\.id))
            throw ADBError.identityUnavailable
        }
        let serials = Set(aliases.compactMap { verified[$0.id] })
        guard serials.count == 1, let serial = serials.first else {
            rejected.formUnion(aliases.map(\.id))
            throw ADBError.identityMismatch
        }
        guard expected == nil || expected == serial else {
            rejected.formUnion(aliases.map(\.id))
            throw ADBError.identityMismatch
        }
        return serial
    }
    private func normalizedName(_ name: String, fallback: String) -> String {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return value.isEmpty ? String(fallback.prefix(120)) : value
    }
    private func connectAndVerify(_ endpoint: Endpoint, expected: SavedDevice?, name: String, before: DiscoverySnapshot) async throws -> ConnectionResult {
        verified.removeAll()
        rejected.removeAll()
        try await client.connect(endpoint)
        let after = try await freshSnapshot()
        try await verify(onlineWireless(in: after))
        let matches = candidates(for: endpoint, in: after)
        guard let target = matches.first(where: { $0.endpoint == endpoint }) ?? matches.first else { throw ADBError.notConnected }
        let serial: String
        do { serial = try requireIdentity(of: matches, expected: expected?.hardwareSerial) }
        catch {
            // Preserve every preexisting transport, including offline/unauthorized aliases.
            let existed = before.transports.contains { old in
                old.id == target.id || old.endpoint == endpoint ||
                before.services.contains(where: { $0.isConnect && $0.endpoint == endpoint && $0.matches(transport: old) }) ||
                after.services.contains(where: { $0.isConnect && $0.endpoint == endpoint && $0.matches(transport: old) })
            }
            // Named aliases may have been created by auto-discovery or another
            // tool. Only a single new direct endpoint can be cleaned up here.
            if error as? ADBError == .identityMismatch, !existed,
               matches.count == 1, target.endpoint == endpoint, verified[target.id] != nil {
                verified.removeValue(forKey: target.id)
                let live = (try? await client.devices()) ?? []
                if live.contains(where: { $0.id == target.id && $0.isWireless && !$0.isEmulator }) {
                    try? await client.disconnect(target)
                }
            }
            throw error
        }
        return result(for: target, endpoint: endpoint, serial: serial, expected: expected, name: name, snapshot: after)
    }
    private func result(for target: ADBTransport, endpoint: Endpoint, serial: String, expected: SavedDevice?, name: String, snapshot: DiscoverySnapshot) -> ConnectionResult {
        let services = snapshot.services.filter { $0.isConnect && $0.endpoint == endpoint && $0.matches(transport: target) }
        let bound = services.filter { $0.matches(serial: serial) }
        let identity = bound.count == 1 ? bound[0].name : (services.count == 1 ? services[0].name : nil)
        var device = expected ?? SavedDevice(name: normalizedName(name, fallback: target.displayName), hardwareSerial: serial, lastEndpoint: endpoint)
        device.lastEndpoint = endpoint; device.lastConnected = Date()
        if let identity { device.mdnsIdentity = identity }
        return ConnectionResult(device: device, transportID: target.id, snapshot: snapshot)
    }
}

public enum SavedConnectionStatus: Equatable, Sendable {
    case connected(ADBTransport), discovered, offline, unauthorized, unavailable
    public static func resolve(_ saved: SavedDevice, snapshot: DiscoverySnapshot, verified: [String: String], rejected: Set<String> = []) -> SavedConnectionStatus {
        let services = snapshot.services.filter { $0.isConnect && ($0.matches(serial: saved.hardwareSerial) || $0.name == saved.mdnsIdentity) }
        let matching = snapshot.transports.filter { transport in
            guard !rejected.contains(transport.id) else { return false }
            if let actual = verified[transport.id] { return actual == saved.hardwareSerial }
            return services.contains(where: { $0.matches(transport: transport) })
        }
        if let online = matching.first(where: {
            $0.state == .device && $0.isWireless && !$0.isEmulator && verified[$0.id] == saved.hardwareSerial
        }) { return .connected(online) }
        if matching.contains(where: { $0.state == .unauthorized }) { return .unauthorized }
        if matching.contains(where: { $0.state == .offline }) { return .offline }
        return services.isEmpty ? .unavailable : .discovered
    }
}
