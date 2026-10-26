import XCTest
@testable import ADBCore

final class IdentityTests: XCTestCase {
    typealias Step = ScriptedExecutor.Step
    let endpoint = try! Endpoint("10.0.0.4:40000")
    let changed = try! Endpoint("10.0.0.4:45000")
    let firstAlias = "adb-ABC-one._adb-tls-connect._tcp"
    let secondAlias = "adb-ABC-two._adb-tls-connect._tcp."
    var saved: SavedDevice { SavedDevice(name: "Phone", hardwareSerial: "ABC", lastEndpoint: endpoint) }
    func core(_ executor: any ProcessExecuting) -> ConnectionCoordinator {
        ConnectionCoordinator(client: ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor))
    }
    func snapshot(_ devices: String = "", _ services: String = "", mdnsStatus: Int32 = 0) -> [Step] {
        [Step(["devices", "-l"], devices), Step(["mdns", "services"], services, status: mdnsStatus)]
    }
    func serial(_ id: String, _ value: String, status: Int32 = 0) -> Step {
        Step(["-s", id, "shell", "getprop", "ro.serialno"], value, status: status)
    }
    var aliases: String { "\(firstAlias) device\n\(secondAlias) device" }
    var services: String {
        "adb-ABC-one _adb-tls-connect._tcp \(changed)\nadb-ABC-two _adb-tls-connect._tcp \(changed)"
    }

    func testRefreshRevalidatesSameEndpointReplacement() async throws {
        let hint = "adb-ABC-old _adb-tls-connect._tcp \(endpoint)"
        let executor = ScriptedExecutor(snapshot("\(endpoint) device", hint) + [serial(endpoint.description, "ABC")] + snapshot("\(endpoint) device", hint) + [serial(endpoint.description, "OTHER")])
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        let initial = await coordinator.verifiedSerials()
        XCTAssertEqual(initial[endpoint.description], "ABC")
        let latest = try await coordinator.refresh()
        let verified = await coordinator.verifiedSerials()
        XCTAssertEqual(verified, [endpoint.description: "OTHER"])
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: latest, verified: verified), .discovered)
    }

    func testFailedRefreshClearsCacheBeforeRecovery() async throws {
        let executor = ScriptedExecutor(snapshot("\(endpoint) device") + [serial(endpoint.description, "ABC"), Step(["devices", "-l"], status: 1)] + snapshot("\(endpoint) device") + [serial(endpoint.description, "OTHER")])
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.refresh(); XCTFail("snapshot must fail") }
        catch { XCTAssertEqual(error as? ADBError, .commandFailed) }
        let cleared = await coordinator.verifiedSerials()
        XCTAssertTrue(cleared.isEmpty)
        _ = try await coordinator.refresh()
        let recovered = await coordinator.verifiedSerials()
        XCTAssertEqual(recovered, [endpoint.description: "OTHER"])
    }

    func testFailedIdentityQueryDoesNotRetainCachedSerial() async throws {
        let executor = ScriptedExecutor(snapshot("\(endpoint) device") + [serial(endpoint.description, "ABC")] + snapshot("\(endpoint) device") + [serial(endpoint.description, "", status: 1)])
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        _ = try await coordinator.refresh()
        let verified = await coordinator.verifiedSerials()
        let rejected = await coordinator.rejectedTransports()
        XCTAssertTrue(verified.isEmpty)
        XCTAssertEqual(rejected, [endpoint.description])
    }

    func testStartupReconnectReusesActualOnlineSerialWithoutMDNSOrConnect() async throws {
        let executor = ScriptedExecutor(snapshot("USB123 device usb:1\nemulator-5554 device\n\(changed) device", mdnsStatus: 1) + [serial(changed.description, "ABC")])
        let bookmark = saved
        let result = try await core(executor).reconnect(bookmark)
        XCTAssertEqual(result.device.lastEndpoint, changed)
        XCTAssertEqual(result.device.id, bookmark.id)
        XCTAssertEqual(result.transportID, changed.description)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].timeout, 2) // Unavailable discovery must not stall online reuse.
        XCTAssertEqual(requests.last?.timeout, 2)
    }

    func testStartupReconnectFindsHardwareRatherThanTrustingLastEndpoint() async throws {
        let executor = ScriptedExecutor(snapshot("\(endpoint) device\n\(changed) device") + [serial(endpoint.description, "OTHER"), serial(changed.description, "ABC")])
        let coordinator = core(executor)
        let result = try await coordinator.reconnect(saved)
        XCTAssertEqual(result.transportID, changed.description)
        XCTAssertEqual(result.device.lastEndpoint, changed)
        let verified = await coordinator.verifiedSerials()
        XCTAssertEqual(verified[endpoint.description], "OTHER")
    }

    func testOnlineNamedAliasesCollapseOnlyAfterBothAreVerified() async throws {
        let executor = ScriptedExecutor(snapshot(aliases, services) + [serial(firstAlias, "ABC"), serial(secondAlias, "ABC")])
        let result = try await core(executor).reconnect(saved)
        XCTAssertEqual(result.device.lastEndpoint, changed)
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { $0.arguments.first == "connect" })
        XCTAssertEqual(requests.filter { $0.arguments.first == "-s" }.count, 2)
    }

    func testConflictingOnlineAliasesAreRejectedWithoutDisconnecting() async throws {
        let executor = ScriptedExecutor(snapshot(aliases, services) + [serial(firstAlias, "ABC"), serial(secondAlias, "OTHER")])
        let coordinator = core(executor)
        do { _ = try await coordinator.reconnect(saved); XCTFail("conflicting aliases") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { ["connect", "disconnect"].contains($0.arguments.first ?? "") })
        let rejected = await coordinator.rejectedTransports()
        XCTAssertEqual(rejected, [firstAlias, secondAlias])
    }

    func testUnverifiedAliasCannotCollapseIntoVerifiedOnlineDevice() async throws {
        let executor = ScriptedExecutor(snapshot(aliases, services) + [serial(firstAlias, "ABC"), serial(secondAlias, "", status: 1)])
        do { _ = try await core(executor).reconnect(saved); XCTFail("unknown alias identity") }
        catch { XCTAssertEqual(error as? ADBError, .identityUnavailable) }
    }

    func testConnectCollapsesNewNamedAliasesAfterSerialVerification() async throws {
        let executor = ScriptedExecutor(snapshot() + [Step(["connect", changed.description])] + snapshot(aliases, services) + [serial(firstAlias, "ABC"), serial(secondAlias, "ABC")])
        let result = try await core(executor).connect(changed, name: "Phone")
        XCTAssertEqual(result.device.hardwareSerial, "ABC")
        XCTAssertEqual(result.device.lastEndpoint, changed)
    }

    func testExplicitEndpointDoesNotHideConflictingNamedAlias() async throws {
        let executor = ScriptedExecutor(snapshot("\(changed) offline", services) + [Step(["connect", changed.description])] + snapshot("\(changed) device\n\(firstAlias) device", services) + [serial(changed.description, "ABC"), serial(firstAlias, "OTHER")])
        do { _ = try await core(executor).connect(changed, name: "Phone"); XCTFail("explicit address cannot override conflict") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
    }

    func testMismatchCleanupPreservesOfflineAndUnauthorizedPreexistingTargets() async throws {
        for state in ["offline", "unauthorized"] {
            let executor = ScriptedExecutor(snapshot("\(endpoint) \(state)") + [Step(["connect", endpoint.description])] + snapshot("\(endpoint) device") + [serial(endpoint.description, "OTHER")])
            do { _ = try await core(executor).reconnect(saved); XCTFail("wrong hardware") }
            catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
            let requests = await executor.requests
            XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
        }
    }

    func testMismatchCleanupPreservesPreexistingNamedUnauthorizedAlias() async throws {
        let hint = "adb-ABC-one _adb-tls-connect._tcp \(endpoint)"
        let executor = ScriptedExecutor(snapshot("\(firstAlias) unauthorized", hint) + [Step(["connect", endpoint.description])] + snapshot("\(endpoint) device", hint) + [serial(endpoint.description, "OTHER")])
        do { _ = try await core(executor).reconnect(saved); XCTFail("wrong hardware") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
    }

    func testNamedTransportWithoutDiscoveryReusesLiveIdentityAndRetainsHistory() async throws {
        for status: Int32 in [0, 1] {
            let executor = ScriptedExecutor(snapshot("\(firstAlias) device", mdnsStatus: status) + [serial(firstAlias, "ABC")])
            let bookmark = saved
            let result = try await core(executor).reconnect(bookmark)
            XCTAssertEqual(result.device.lastEndpoint, endpoint)
            XCTAssertEqual(result.device.id, bookmark.id)
            XCTAssertEqual(result.device.name, bookmark.name)
            XCTAssertEqual(result.transportID, firstAlias)
            XCTAssertTrue(result.snapshot.services.isEmpty)
            let remaining = await executor.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testSaveConnectedRejectsConflictingIdentityAliases() async throws {
        let executor = ScriptedExecutor(snapshot("\(changed) device\n\(firstAlias) device", services) + [serial(changed.description, "ABC"), serial(firstAlias, "OTHER")])
        let transport = ADBParser.devices("\(changed) device")[0]
        do { _ = try await core(executor).saveConnected(transport, name: "Phone"); XCTFail("conflicting aliases") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
    }

    func testRefreshEmptyAndNonWirelessDevicesNeverQueriesIdentity() async throws {
        let executor = ScriptedExecutor(snapshot() + snapshot("USB123 device usb:1\nemulator-5554 device\n10.0.0.5:40000 offline\n10.0.0.6:40000 unauthorized\n10.0.0.7:40000 device usb:2"))
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        _ = try await coordinator.refresh()
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(requests.contains { $0.arguments.first == "-s" })
    }

    func testRefreshBoundsConcurrencyAndIdentityTimeout() async throws {
        let executor = ConcurrentIdentityExecutor()
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        let verified = await coordinator.verifiedSerials()
        let requests = await executor.identityRequests
        let maximum = await executor.maximum
        XCTAssertEqual(verified.count, 9)
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(maximum, 4)
        XCTAssertTrue(requests.allSatisfy { $0.timeout == 2 })
    }
}

private actor ConcurrentIdentityExecutor: ProcessExecuting {
    private var active = 0
    private(set) var maximum = 0
    private(set) var identityRequests: [ProcessRequest] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments == ["devices", "-l"] {
            return ProcessResult(status: 0, stdout: (1...9).map { "10.0.0.\($0):40000 device" }.joined(separator: "\n"))
        }
        if request.arguments == ["mdns", "services"] { return ProcessResult(status: 0) }
        guard request.arguments.first == "-s" else { XCTFail("unexpected command"); throw ADBError.commandFailed }
        identityRequests.append(request)
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        return ProcessResult(status: 0, stdout: "SERIAL")
    }
}
