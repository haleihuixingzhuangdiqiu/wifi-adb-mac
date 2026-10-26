import XCTest
@testable import ADBCore

final class StorageTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WiFiADB-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testMissingFileRoundTripAndOnlyBookmarkFieldsPersist() throws {
        let storage = DeviceStorage(directory: try temporaryDirectory())
        XCTAssertEqual(try storage.load(), [])
        let device = SavedDevice(name: "我的手机", hardwareSerial: "ABC-123", mdnsIdentity: "adb-ABC-123-a (2).", lastEndpoint: try Endpoint("[::1]:33333"))
        try storage.save([device])
        XCTAssertEqual(try storage.load(), [device])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.fileURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let entries = try XCTUnwrap(object["devices"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), Set(["id", "name", "hardwareSerial", "mdnsIdentity", "lastEndpoint", "lastConnected"]))
        try storage.save([])
        XCTAssertEqual(try storage.load(), [])
    }
    func testMalformedFileIsPreservedAndVisibleError() throws {
        let storage = DeviceStorage(directory: try temporaryDirectory())
        let data = Data("{broken original data".utf8)
        try data.write(to: storage.fileURL)
        XCTAssertThrowsError(try storage.load()) { XCTAssertEqual($0 as? ADBError, .storageRead) }
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), data)
    }
    func testDecodeRevalidatesEndpointInsteadOfTrustingJSON() throws {
        let storage = DeviceStorage(directory: try temporaryDirectory())
        let device = SavedDevice(name: "Phone", hardwareSerial: "ABC", lastEndpoint: try Endpoint("10.0.0.4:5555"))
        try storage.save([device])
        let text = try String(contentsOf: storage.fileURL, encoding: .utf8)
        try text.replacingOccurrences(of: "10.0.0.4", with: "--evil").write(to: storage.fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.load())
    }
    func testDuplicateHardwareIdentitiesAreRejected() throws {
        let storage = DeviceStorage(directory: try temporaryDirectory())
        let a = SavedDevice(name: "A", hardwareSerial: "ABC", lastEndpoint: try Endpoint("10.0.0.4:5555"))
        let b = SavedDevice(name: "B", hardwareSerial: "ABC", lastEndpoint: try Endpoint("10.0.0.5:5555"))
        try storage.save([a, b])
        XCTAssertThrowsError(try storage.load())
    }
    func testEnvironmentOverrideDoesNotFallBackSilently() {
        XCTAssertEqual(ADBLocation.detect(environment: ["WIFIADB_ADB_PATH": "/not-installed/adb"])?.path, "/not-installed/adb")
    }
}
