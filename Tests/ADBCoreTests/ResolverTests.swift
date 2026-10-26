import XCTest
@testable import ADBCore

final class ResolverTests: XCTestCase {
    let old = try! Endpoint("10.0.0.4:40000")
    var saved: SavedDevice { SavedDevice(name: "Pixel", hardwareSerial: "ABC-123", mdnsIdentity: "observed-guid", lastEndpoint: old) }
    func services(_ lines: String) -> [MDNSService] { ADBParser.mdns(lines) }

    func testChangedPortUsesExactSerialPrefix() throws {
        let discovered = services("adb-ABC-123-new _adb-tls-connect._tcp 10.0.0.4:45000\nadb-ABC-1234-other _adb-tls-connect._tcp 10.0.0.8:45001")
        XCTAssertEqual(try ReconnectResolver.endpoint(for: saved, services: discovered).port, 45000)
    }
    func testExactPreviouslyObservedServiceCanResolve() throws {
        let discovered = services("observed-guid _adb-tls-connect._tcp [::1]:45123")
        XCTAssertEqual(try ReconnectResolver.endpoint(for: saved, services: discovered).description, "[::1]:45123")
    }
    func testRememberedHardwareBoundServiceWinsOverOldRenamedAdvertisement() throws {
        var device = saved
        device.mdnsIdentity = "adb-ABC-123-current (2)"
        let discovered = services("adb-ABC-123-current _adb-tls-connect._tcp 10.0.0.4:40000\nadb-ABC-123-current (2) _adb-tls-connect._tcp 10.0.0.4:45000")
        XCTAssertEqual(try ReconnectResolver.endpoint(for: device, services: discovered).port, 45000)
        let conflicting = discovered + services("adb-ABC-123-current (2) _adb-tls-connect._tcp 10.0.0.9:46000")
        XCTAssertThrowsError(try ReconnectResolver.endpoint(for: device, services: conflicting))
    }
    func testMultipleCandidatesRejectRatherThanPreferOldAddress() {
        let discovered = services("adb-ABC-123-a _adb-tls-connect._tcp 10.0.0.4:40000\nobserved-guid _adb-tls-connect._tcp 10.0.0.7:45555")
        XCTAssertThrowsError(try ReconnectResolver.endpoint(for: saved, services: discovered)) { XCTAssertEqual($0 as? ADBError, .ambiguous) }
    }
    func testPairingAndUnrelatedModelsNeverResolve() throws {
        let discovered = services("adb-ABC-123-new _adb-tls-pairing._tcp 10.0.0.4:49000\nPixel _adb-tls-connect._tcp 10.0.0.2:40000")
        XCTAssertEqual(try ReconnectResolver.endpoint(for: saved, services: discovered), old)
        XCTAssertEqual(try ReconnectResolver.endpoint(for: saved, services: []), old)
    }
    func testPersistedIPNeverImpliesConnected() {
        let snapshot = DiscoverySnapshot(transports: ADBParser.devices("10.0.0.4:40000 device model:Pixel"))
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: snapshot, verified: [:]), .unavailable)
        if case .connected = SavedConnectionStatus.resolve(saved, snapshot: snapshot, verified: ["10.0.0.4:40000": "ABC-123"]) {} else { XCTFail("session verification should bind") }
    }
    func testDiscoveryIsNotConnectionAndAuthorizationIsVisible() {
        let service = services("adb-ABC-123-new _adb-tls-connect._tcp 10.0.0.4:45000")
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: DiscoverySnapshot(services: service), verified: [:]), .discovered)
        let unauthorized = DiscoverySnapshot(transports: ADBParser.devices("10.0.0.4:45000 unauthorized"), services: service)
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: unauthorized, verified: [:]), .unauthorized)
        let online = DiscoverySnapshot(transports: ADBParser.devices("adb-ABC-123-new._adb-tls-connect._tcp device"), services: service)
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: online, verified: [:]), .discovered)
        let id = online.transports[0].id
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: online, verified: [id: "OTHER"]), .discovered)
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: online, verified: [id: saved.hardwareSerial]), .connected(online.transports[0]))
    }
    func testActualIdentityMismatchAndFailedVerificationOverrideMDNSHint() {
        let services = services("adb-ABC-123-new _adb-tls-connect._tcp 10.0.0.4:45000")
        let snapshot = DiscoverySnapshot(transports: ADBParser.devices("10.0.0.4:45000 device"), services: services)
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: snapshot, verified: ["10.0.0.4:45000": "OTHER"]), .discovered)
        XCTAssertEqual(SavedConnectionStatus.resolve(saved, snapshot: snapshot, verified: [:], rejected: ["10.0.0.4:45000"]), .discovered)
    }
}
