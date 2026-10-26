import XCTest
@testable import ADBCore

final class CoreActionTests: XCTestCase {
    typealias Step = ScriptedExecutor.Step
    let a = "adb-VIVO123-guid (2)._adb-tls-connect._tcp."
    let oldA = "adb-VIVO123-guid._adb-tls-connect._tcp"
    let b = "adb-OTHER456-guid._adb-tls-connect._tcp"
    let address = try! Endpoint("10.0.0.8:42000")
    var devices: String { "OTHER456 device usb:1 model:Other_Phone\n\(b) device model:Other_Phone\n\(a) device model:Vivo_Phone" }
    var services: String {
        "adb-VIVO123-guid _adb-tls-connect._tcp 10.0.0.8:41000\nadb-VIVO123-guid (2) _adb-tls-connect._tcp 10.0.0.8:42000\nadb-OTHER456-guid _adb-tls-connect._tcp 10.0.0.9:43000"
    }
    func snapshot(_ devices: String, _ services: String = "") -> [Step] {
        [Step(["devices", "-l"], devices), Step(["mdns", "services"], services)]
    }
    func serial(_ id: String, _ value: String, status: Int32 = 0) -> Step {
        Step(["-s", id, "shell", "getprop", "ro.serialno"], value, status: status)
    }
    func core(_ executor: ScriptedExecutor) -> ConnectionCoordinator {
        ConnectionCoordinator(client: ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor))
    }
    func transport(_ id: String) -> ADBTransport { ADBParser.devices("\(id) device")[0] }

    func testSaveAAndConnectAKeepBVerifiedWithoutAttributingUSBIdentity() async throws {
        for save in [true, false] {
            let start = save ? [] : snapshot(devices, services) + [Step(["connect", address.description])]
            let executor = ScriptedExecutor(start + snapshot(devices, services) + [serial(a, "VIVO123"), serial(b, "OTHER456")])
            let coordinator = core(executor)
            let result: ConnectionResult
            if save { result = try await coordinator.saveConnected(transport(a), name: "Vivo") }
            else { result = try await coordinator.connect(address, name: "Vivo") }
            let verified = await coordinator.verifiedSerials()
            XCTAssertEqual(verified, [a: "VIVO123", b: "OTHER456"])
            XCTAssertEqual(result.device.mdnsIdentity, "adb-VIVO123-guid (2)")
            XCTAssertEqual(result.snapshot.transports.count, 3)
            let savedB = SavedDevice(name: "Other", hardwareSerial: "OTHER456", lastEndpoint: try Endpoint("10.0.0.9:43000"))
            XCTAssertEqual(SavedConnectionStatus.resolve(savedB, snapshot: result.snapshot, verified: verified), .connected(transportWithModel(b)))
            let requests = await executor.requests
            XCTAssertFalse(requests.contains { $0.arguments == ["-s", "OTHER456", "shell", "getprop", "ro.serialno"] })
        }
    }
    private func transportWithModel(_ id: String) -> ADBTransport { ADBParser.devices("\(id) device model:Other_Phone")[0] }

    func testAddresslessSaveExplainsRequiredAddressAndRevalidatesAllIdentities() async throws {
        let executor = ScriptedExecutor(snapshot(devices) + [serial(a, "VIVO123"), serial(b, "OTHER456")])
        let coordinator = core(executor)
        do { _ = try await coordinator.saveConnected(transport(a), name: "Vivo"); XCTFail("address required") }
        catch {
            XCTAssertEqual(error as? ADBError, .addressRequired)
            XCTAssertTrue(error.localizedDescription.contains("添加设备"))
        }
        let verified = await coordinator.verifiedSerials()
        XCTAssertEqual(verified, [a: "VIVO123", b: "OTHER456"])
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { ["connect", "disconnect"].contains($0.arguments.first ?? "") })
    }

    func testExactNamedDisconnectWorksWithoutDiscoveryAndRetainsOtherRows() async throws {
        let executor = ScriptedExecutor([Step(["devices", "-l"], devices), Step(["disconnect", a])] + snapshot("OTHER456 device usb:1\n\(b) device") + [serial(b, "OTHER456")])
        let coordinator = core(executor)
        try await coordinator.disconnect(transport(a))
        let invalidated = await coordinator.verifiedSerials()
        XCTAssertTrue(invalidated.isEmpty)
        let after = try await coordinator.refresh()
        XCTAssertEqual(after.transports.map(\.id), ["OTHER456", b])
        let requests = await executor.requests
        XCTAssertEqual(requests.filter { $0.arguments.first == "disconnect" }.map(\.arguments), [["disconnect", a]])
    }

    func testDisconnectRevalidatesPresenceAndUSBClassification() async {
        for listing in ["\(oldA) device\n\(b) device", "\(a) device usb:1"] {
            let executor = ScriptedExecutor([Step(["devices", "-l"], listing)])
            do { try await core(executor).disconnect(transport(a)); XCTFail("stale target") }
            catch { XCTAssertEqual(error as? ADBError, .notConnected) }
            let requests = await executor.requests
            XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
        }
    }

    func testDisconnectFailureInvalidatesPreviousIdentity() async throws {
        let executor = ScriptedExecutor(snapshot("\(a) device") + [serial(a, "VIVO123"), Step(["devices", "-l"], "\(a) device"), Step(["disconnect", a], status: 1)])
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        do { try await coordinator.disconnect(transport(a)); XCTFail("failed command") }
        catch { XCTAssertEqual(error as? ADBError, .commandFailed) }
        let verified = await coordinator.verifiedSerials()
        let rejected = await coordinator.rejectedTransports()
        XCTAssertTrue(verified.isEmpty)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testClientRejectsUnsafeDisconnectTargetsWithoutExecuting() async {
        let executor = ScriptedExecutor([])
        let client = ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor)
        for id in ["", "--all", " -s", "emulator-5554", "USB123", "adb-x._adb-tls-connect._tcp\n", "adb-x\t._adb-tls-connect._tcp", "adb-x;id._adb-tls-connect._tcp", String(repeating: "a", count: 513) + "._adb-tls-connect._tcp"] {
            let target = ADBTransport(id: id, state: .device, model: nil, usb: false)
            do { try await client.disconnect(target); XCTFail("invalid target accepted") }
            catch { XCTAssertEqual(error as? ADBError, .notConnected) }
        }
        let usb = ADBTransport(id: address.description, state: .device, model: nil, usb: true)
        do { try await client.disconnect(usb); XCTFail("USB target accepted") } catch {}
        let requests = await executor.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMismatchPreservesNewNamedConnectionWithUnknownOwnership() async throws {
        let executor = ScriptedExecutor(snapshot("\(b) device", services) + [serial(b, "OTHER456"), Step(["connect", address.description])] + snapshot(devices, services) + [serial(a, "WRONG"), serial(b, "OTHER456")])
        let coordinator = core(executor)
        let saved = SavedDevice(name: "Vivo", hardwareSerial: "VIVO123", mdnsIdentity: "adb-VIVO123-guid (2)", lastEndpoint: address)
        do { _ = try await coordinator.reconnect(saved); XCTFail("mismatch") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
        let verified = await coordinator.verifiedSerials()
        XCTAssertEqual(verified[b], "OTHER456")
        let rejected = await coordinator.rejectedTransports()
        XCTAssertTrue(rejected.contains(a))
    }

    func testMismatchWithNewDirectAndNamedAliasPreservesBothConnections() async throws {
        let executor = ScriptedExecutor(snapshot("") + [Step(["connect", address.description])] + snapshot("\(address) device\n\(a) device", services) + [serial(address.description, "WRONG"), serial(a, "WRONG")])
        let coordinator = core(executor)
        let saved = SavedDevice(name: "Vivo", hardwareSerial: "VIVO123", lastEndpoint: address)
        do { _ = try await coordinator.reconnect(saved); XCTFail("wrong identity") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let requests = await executor.requests
        XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
        let remaining = await executor.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testFailedConnectVerificationKeepsOnlyFreshSiblingIdentity() async throws {
        let executor = ScriptedExecutor(snapshot(devices, services) + [serial(a, "VIVO123"), serial(b, "OTHER456")] + snapshot(devices, services) + [Step(["connect", address.description])] + snapshot(devices, services) + [serial(a, "", status: 1), serial(b, "REPLACEMENT")])
        let coordinator = core(executor)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.connect(address, name: "Vivo"); XCTFail("failed identity") }
        catch { XCTAssertEqual(error as? ADBError, .identityUnavailable) }
        let verified = await coordinator.verifiedSerials()
        let rejected = await coordinator.rejectedTransports()
        XCTAssertEqual(verified, [b: "REPLACEMENT"])
        XCTAssertEqual(rejected, [a])
    }

    func testCleanupRevalidatesNewTransportAndNeverDisconnectsAbsentOrUSBTarget() async {
        for latest in ["\(b) device", "\(address) device usb:1\n\(b) device"] {
            let executor = ScriptedExecutor(snapshot("") + [Step(["connect", address.description])] + snapshot("\(address) device", services) + [serial(address.description, "WRONG"), Step(["devices", "-l"], latest)])
            let coordinator = core(executor)
            let saved = SavedDevice(name: "Vivo", hardwareSerial: "VIVO123", lastEndpoint: address)
            do { _ = try await coordinator.reconnect(saved); XCTFail("wrong device") }
            catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
            let requests = await executor.requests
            let verified = await coordinator.verifiedSerials()
            XCTAssertFalse(requests.contains { $0.arguments.first == "disconnect" })
            XCTAssertTrue(verified.isEmpty)
        }
    }

    func testSaveSnapshotExpiresFailedOrOfflineSiblingIdentity() async throws {
        for siblingState in ["device", "offline", "unauthorized"] {
            let second = "\(a) device\n\(b) \(siblingState)"
            let queries = [serial(a, "VIVO123")] + (siblingState == "device" ? [serial(b, "", status: 1)] : [])
            let executor = ScriptedExecutor(snapshot(devices, services) + [serial(a, "VIVO123"), serial(b, "OTHER456")] + snapshot(second, services) + queries)
            let coordinator = core(executor)
            _ = try await coordinator.refresh()
            _ = try await coordinator.saveConnected(transport(a), name: "Vivo")
            let verified = await coordinator.verifiedSerials()
            XCTAssertEqual(verified, [a: "VIVO123"])
        }
    }
}
