import XCTest
@testable import ADBCore

actor ScriptedExecutor: ProcessExecuting {
    struct Step: Sendable {
        let arguments: [String]
        var result: ProcessResult
        init(_ arguments: [String], _ output: String = "", status: Int32 = 0) {
            self.arguments = arguments; self.result = ProcessResult(status: status, stdout: output)
        }
    }
    private var steps: [Step]
    private(set) var requests: [ProcessRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        guard !steps.isEmpty else { XCTFail("unexpected request \(request.arguments)"); throw ADBError.commandFailed }
        // Concurrent identity queries may arrive in either order within a scripted batch.
        let batch = steps.prefix { $0.arguments.first == "-s" }
        let index = batch.firstIndex { $0.arguments == request.arguments } ?? 0
        let step = steps.remove(at: index)
        XCTAssertEqual(request.arguments, step.arguments)
        guard request.arguments == step.arguments else { throw ADBError.commandFailed }
        return step.result
    }
    var remaining: Int { steps.count }
}

final class CoordinatorTests: XCTestCase {
    typealias Step = ScriptedExecutor.Step
    let endpoint = try! Endpoint("10.0.0.4:40000")
    let fresh = "adb-ABC-new _adb-tls-connect._tcp 10.0.0.4:45000"
    var saved: SavedDevice { SavedDevice(name: "My phone", hardwareSerial: "ABC", lastEndpoint: endpoint) }
    func coordinator(_ executor: ScriptedExecutor) -> ConnectionCoordinator {
        ConnectionCoordinator(client: ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor))
    }
    func snapshot(_ devices: String = "", _ services: String = "") -> [Step] {
        [Step(["devices", "-l"], devices), Step(["mdns", "services"], services)]
    }
    func testReconnectDiscoversFreshPortThenVerifiesBeforeUpdating() async throws {
        let executor = ScriptedExecutor(snapshot("", fresh) + [Step(["connect", "10.0.0.4:45000"], "connected")] + snapshot("10.0.0.4:45000 device model:Pixel_9", fresh) + [Step(["-s", "10.0.0.4:45000", "shell", "getprop", "ro.serialno"], "ABC\n")])
        let device = saved
        let result = try await coordinator(executor).reconnect(device)
        XCTAssertEqual(result.device.lastEndpoint.port, 45000)
        XCTAssertEqual(result.device.id, device.id)
    }
    func testReconnectPreservesBookmarkIDAndName() async throws {
        let device = saved
        let executor = ScriptedExecutor(snapshot() + [Step(["connect", endpoint.description])] + snapshot("\(endpoint) device model:Other") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "ABC")])
        let result = try await coordinator(executor).reconnect(device)
        XCTAssertEqual(result.device.id, device.id)
        XCTAssertEqual(result.device.name, "My phone")
        XCTAssertEqual(result.device.hardwareSerial, "ABC")
        let remaining = await executor.remaining
        XCTAssertEqual(remaining, 0)
    }
    func testAmbiguousDiscoveryNeverCallsConnect() async throws {
        let executor = ScriptedExecutor(snapshot("", fresh + "\nadb-ABC-second _adb-tls-connect._tcp 10.0.0.5:44000"))
        do { _ = try await coordinator(executor).reconnect(saved); XCTFail("must reject ambiguity") }
        catch { XCTAssertEqual(error as? ADBError, .ambiguous) }
        let calls = await executor.requests
        XCTAssertFalse(calls.contains(where: { $0.arguments.first == "connect" }))
    }
    func testWrongIdentityCleansOnlyNewlyEstablishedTransport() async {
        let executor = ScriptedExecutor(snapshot() + [Step(["connect", endpoint.description])] + snapshot("\(endpoint) device") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "WRONG"), Step(["devices", "-l"], "\(endpoint) device"), Step(["disconnect", endpoint.description])])
        do { _ = try await coordinator(executor).reconnect(saved); XCTFail("identity mismatch") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let remaining = await executor.remaining
        XCTAssertEqual(remaining, 0)
    }
    func testWrongIdentityNeverDisconnectsPreexistingTransport() async {
        let executor = ScriptedExecutor(snapshot("\(endpoint) device") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "WRONG"), Step(["connect", endpoint.description])] + snapshot("\(endpoint) device") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "WRONG")])
        do { _ = try await coordinator(executor).reconnect(saved); XCTFail("identity mismatch") }
        catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let calls = await executor.requests
        XCTAssertFalse(calls.contains(where: { $0.arguments.first == "disconnect" }))
    }
    func testFailedVerificationCannotBecomeGreenFromStaleMDNS() async throws {
        let mdns = "adb-ABC-stale _adb-tls-connect._tcp \(endpoint)"
        let executor = ScriptedExecutor(snapshot("\(endpoint) device", mdns) + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "WRONG"), Step(["connect", endpoint.description])] + snapshot("\(endpoint) device", mdns) + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "WRONG")] + snapshot("\(endpoint) device", mdns) + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "WRONG")])
        let core = coordinator(executor)
        let device = saved
        do { _ = try await core.reconnect(device); XCTFail("must fail") } catch { XCTAssertEqual(error as? ADBError, .identityMismatch) }
        let after = try await core.refresh()
        let identities = await core.verifiedSerials()
        let rejected = await core.rejectedTransports()
        XCTAssertEqual(SavedConnectionStatus.resolve(device, snapshot: after, verified: identities, rejected: rejected), .discovered)
        XCTAssertEqual(identities[endpoint.description], "WRONG")
    }
    func testEmptySerialCannotClaimSuccess() async {
        let executor = ScriptedExecutor(snapshot() + [Step(["connect", endpoint.description])] + snapshot("\(endpoint) device") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "")])
        let core = coordinator(executor)
        do { _ = try await core.reconnect(saved); XCTFail("empty serial") }
        catch { XCTAssertEqual(error as? ADBError, .identityUnavailable) }
        let verified = await core.verifiedSerials()
        XCTAssertTrue(verified.isEmpty)
    }
    func testZeroExitFailedConnectRequiresActualOnlineDevice() async {
        let executor = ScriptedExecutor(snapshot() + [Step(["connect", endpoint.description], "failed to connect")] + snapshot())
        do { _ = try await coordinator(executor).reconnect(saved); XCTFail("must not trust exit status") }
        catch { XCTAssertEqual(error as? ADBError, .notConnected) }
    }
    func testTLSNamedTransportIsVerifiedOnExactTarget() async throws {
        let name = "adb-ABC-new._adb-tls-connect._tcp"
        let executor = ScriptedExecutor(snapshot("", fresh) + [Step(["connect", "10.0.0.4:45000"])] + snapshot("\(name) device model:Pixel_9", fresh) + [Step(["-s", name, "shell", "getprop", "ro.serialno"], "ABC")])
        let result = try await coordinator(executor).connect(try Endpoint("10.0.0.4:45000"), name: "")
        XCTAssertEqual(result.device.name, "Pixel 9")
        XCTAssertEqual(result.device.mdnsIdentity, "adb-ABC-new")
    }
    func testExplicitSaveRejectsUSBWithoutQueryingHardware() async {
        let transport = ADBParser.devices("USB123 device usb:abc")[0]
        let executor = ScriptedExecutor(snapshot("USB123 device usb:abc"))
        do { _ = try await coordinator(executor).saveConnected(transport, name: "USB"); XCTFail("USB is not a wireless bookmark") }
        catch { XCTAssertEqual(error as? ADBError, .notConnected) }
    }
    func testPairSecretIsStdinAndErrorsAreGeneric() async {
        let executor = ScriptedExecutor([Step(["pair", endpoint.description], "echo 684215 failed", status: 1)])
        let client = ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor)
        do { try await client.pair(endpoint, code: "684215"); XCTFail("pair failure") }
        catch {
            XCTAssertEqual(error as? ADBError, .pairingFailed)
            XCTAssertFalse(error.localizedDescription.contains("684215"))
            XCTAssertFalse(error.localizedDescription.contains("echo"))
        }
        let calls = await executor.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].arguments.contains(where: { $0.contains("684215") }))
        XCTAssertEqual(calls[0].standardInput, Data("684215\n".utf8))
        XCTAssertFalse(String(describing: calls[0]).contains("684215"))
        XCTAssertEqual(calls[0].timeout, 30)
    }
    func testPairZeroStatusFailureIsRejectedAndInvalidCodeNeverRuns() async {
        let executor = ScriptedExecutor([Step(["pair", endpoint.description], "error: protocol fault 684215")])
        let client = ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor)
        for code in ["684215", "12345", "１２３４５６", "123456\n"] {
            do { try await client.pair(endpoint, code: code); XCTFail("must reject") } catch {}
        }
        let calls = await executor.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testSuccessfulPairUsesSeparateEndpointAndDoesNotImplicitlyConnectPairingPort() async throws {
        let pairEndpoint = try Endpoint("10.0.0.4:49000")
        let executor = ScriptedExecutor([Step(["pair", pairEndpoint.description], "Enter pairing code: Successfully paired to 10.0.0.4:49000 [guid=adb-ABC]")])
        try await coordinator(executor).pair(pairEndpoint, code: "684215")
        let calls = await executor.requests
        XCTAssertEqual(calls.map(\.arguments), [["pair", pairEndpoint.description]])
    }

    func testRefreshExpiresSessionVerificationWhenTransportGoesOffline() async throws {
        let executor = ScriptedExecutor(snapshot() + [Step(["connect", endpoint.description])] + snapshot("\(endpoint) device") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "ABC")] + snapshot("\(endpoint) offline"))
        let core = coordinator(executor)
        _ = try await core.reconnect(saved)
        let first = await core.verifiedSerials()
        XCTAssertEqual(first[endpoint.description], "ABC")
        _ = try await core.refresh()
        let second = await core.verifiedSerials()
        XCTAssertTrue(second.isEmpty)
    }

    func testMDNSFailureStillAllowsVerifiedOldEndpointFallback() async throws {
        let executor = ScriptedExecutor([Step(["devices", "-l"]), Step(["mdns", "services"], status: 1), Step(["connect", endpoint.description])] + snapshot("\(endpoint) device") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "ABC")])
        let result = try await coordinator(executor).reconnect(saved)
        XCTAssertEqual(result.device.lastEndpoint, endpoint)
        XCTAssertEqual(result.device.hardwareSerial, "ABC")
    }

    func testExplicitWirelessSaveQueriesOnlySelectedTransport() async throws {
        let transport = ADBParser.devices("\(endpoint) device model:Pixel_7")[0]
        let executor = ScriptedExecutor(snapshot("USB123 device usb:abc\n\(endpoint) device model:Pixel_7") + [Step(["-s", endpoint.description, "shell", "getprop", "ro.serialno"], "ABC")])
        let result = try await coordinator(executor).saveConnected(transport, name: "")
        XCTAssertEqual(result.device.hardwareSerial, "ABC")
        XCTAssertEqual(result.device.name, "Pixel 7")
    }

    func testOverlappingRefreshIsRejectedWhileConnectionRuns() async throws {
        let executor = PausingExecutor()
        let core = ConnectionCoordinator(client: ADBClient(executable: URL(fileURLWithPath: "/mock/adb"), executor: executor))
        let operation = Task { try await core.reconnect(saved) }
        await executor.waitUntilStarted()
        do { _ = try await core.refresh(); XCTFail("must serialize operations") }
        catch { XCTAssertEqual(error as? ADBError, .busy) }
        await executor.resume()
        _ = try? await operation.value
    }
}

private actor PausingExecutor: ProcessExecuting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if !started {
            started = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
            }
        }
        return ProcessResult(status: 0)
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
