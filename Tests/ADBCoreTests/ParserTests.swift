import XCTest
@testable import ADBCore

final class ParserTests: XCTestCase {
    func testDevicesToleratesDaemonAndAllTransportKinds() throws {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        USB123 device usb:336592896X product:redfin model:Pixel_5 device:redfin transport_id:1
        emulator-5554 device product:sdk model:sdk_gphone64_arm64
        192.168.1.7:39011 offline
        [2001:db8::1]:42000 unauthorized
        adb-SERIAL-guid._adb-tls-connect._tcp device model:Pixel_9
        recoveryID recovery
        random startup chatter
        """
        let devices = ADBParser.devices(output)
        XCTAssertEqual(devices.count, 6)
        XCTAssertTrue(devices[0].usb)
        XCTAssertFalse(devices[0].isWireless)
        XCTAssertEqual(devices[0].displayName, "Pixel 5")
        XCTAssertTrue(devices[1].isEmulator)
        XCTAssertFalse(devices[1].isWireless)
        XCTAssertEqual(devices[2].state, .offline)
        XCTAssertEqual(devices[3].endpoint?.description, "[2001:db8::1]:42000")
        XCTAssertEqual(devices[3].state, .unauthorized)
        XCTAssertTrue(devices[4].isWireless)
        XCTAssertEqual(devices[5].state, .unknown)
        XCTAssertEqual(ADBParser.devices("List of devices attached\n"), [])
        XCTAssertEqual(ADBParser.devices("USB123 no permissions (missing udev rules)").first?.state, .unknown)
    }

    func testMDNSKeepsPairingSeparateAndParsesIPv6() throws {
        let output = """
        * daemon started successfully
        List of discovered mdns services
        adb-ABC-a _adb-tls-connect._tcp. 192.168.1.7:43121
        adb-ABC-a _adb-tls-connect._tcp. 192.168.1.7:43121
        adb-ABC-b _adb-tls-pairing._tcp. [fe80::1234]:42000
        legacy _adb._tcp 10.0.0.2:5555
        broken _adb-tls-connect._tcp bad;host:20
        """
        let services = ADBParser.mdns(output)
        XCTAssertEqual(services.count, 3)
        XCTAssertTrue(services[0].isConnect)
        XCTAssertFalse(services[1].isConnect)
        XCTAssertEqual(services[1].endpoint.description, "[fe80::1234]:42000")
        XCTAssertTrue(services[0].matches(serial: "ABC"))
        XCTAssertFalse(services[0].matches(serial: "AB"))
        XCTAssertFalse(services[0].matches(serial: "ABC-a"))
    }

    func testAnonymizedThreeTransportListingAndDistinctVivoServiceNames() throws {
        // Same listing structure as the reported snapshot: one phone on USB and
        // wireless, plus a vivo whose current service has the collision suffix.
        let vivo = "adb-VIVO123-a1b2 (2)._adb-tls-connect._tcp."
        let other = "adb-OTHER456-c3d4._adb-tls-connect._tcp"
        for gap in ["    ", "\t"] {
            let devices = ADBParser.devices("""
            List of devices attached
            OTHER456                  device usb:336592896X product:other model:Other_Phone device:other transport_id:1
            \(other)\(gap)device product:other model:Other_Phone device:other transport_id:2
            \(vivo)\(gap)device product:vivo model:Vivo_Phone device:vivo transport_id:3
            """)
            XCTAssertEqual(devices.map(\.id), ["OTHER456", other, vivo])
            XCTAssertTrue(devices[0].usb)
            XCTAssertTrue(devices[1].isWireless)
            XCTAssertTrue(devices[2].isWireless)
            let services = ADBParser.mdns("""
            adb-VIVO123-a1b2\(gap)_adb-tls-connect._tcp.\(gap)10.0.0.8:41000
            adb-VIVO123-a1b2 (2)\(gap)_adb-tls-connect._tcp.\(gap)10.0.0.8:42000
            adb-OTHER456-c3d4.\(gap)_adb-tls-connect._tcp.\(gap)[fe80::1%en0]:43000
            """)
            XCTAssertEqual(services.map(\.name), ["adb-VIVO123-a1b2", "adb-VIVO123-a1b2 (2)", "adb-OTHER456-c3d4."])
            XCTAssertFalse(services[0].matches(transport: devices[2]))
            XCTAssertTrue(services[1].matches(transport: devices[2]))
            XCTAssertTrue(services[2].matches(transport: devices[1]))
        }
    }

    func testTransportValidationPreservesSpacesButRejectsControlsAndOptions() {
        for value in ["adb-A name (2)._adb-tls-connect._tcp.", "adb-A  name (2)._adb-tls-connect._tcp", "[fe80::1%en0]:5555"] {
            XCTAssertTrue(ADBParser.validTransportID(value))
        }
        for value in ["", " ", "-s", "--all", " -s", "name ", "x;id", "$(id)", "x\tname", "x\rname", "x\nname", "x\u{0}name", "x\u{1B}name", String(repeating: "a", count: 513)] {
            XCTAssertFalse(ADBParser.validTransportID(value), "accepted malformed ID")
        }
        for name in ["--all", "x;id", "x\rname", "x\u{0}name", "x\tname"] {
            XCTAssertTrue(ADBParser.devices("\(name) device model:Phone").isEmpty)
            XCTAssertTrue(ADBParser.mdns("\(name) _adb-tls-connect._tcp 10.0.0.8:42000").isEmpty)
        }
        XCTAssertTrue(ADBParser.devices("name device unexpected chatter").isEmpty)
        XCTAssertTrue(ADBParser.mdns("name _adb-tls-connect._tcp 10.0.0.8:42000 junk").isEmpty)
    }

    func testEndpointCanonicalizationAndInjectionRejection() throws {
        XCTAssertEqual(try Endpoint(host: "PHONE.local", portText: "37123").description, "phone.local:37123")
        XCTAssertEqual(try Endpoint("[2001:0db8:0:0:0:0:0:1]:65535").description, "[2001:db8::1]:65535")
        XCTAssertEqual(try Endpoint("[fe80::1%en0]:5555").description, "[fe80::1%en0]:5555")
        for host in ["", "-s", "a b", "a\nb", "a\tb", "a;id", "$(id)", "http://host", "a/b", "a..b", "a_thing", "-host", "host-", "中文", "999.1.1.1", "[::1]x", "::gg"] {
            XCTAssertThrowsError(try Endpoint(host: host, port: 5555), "accepted \(host)")
        }
        for port in ["", "0", "65536", "-1", "1 2", "22\n", "+22", "1;ls", "１"] {
            XCTAssertThrowsError(try Endpoint(host: "localhost", portText: port))
        }
        XCTAssertThrowsError(try Endpoint("2001:db8::1:5555"))
        XCTAssertThrowsError(try Endpoint("[::1]:5555junk"))
        XCTAssertThrowsError(try Endpoint("[fe80::1%en0;id]:5555"))
        XCTAssertThrowsError(try Endpoint("[fe80::1%]:5555"))
    }

    func testSerialAndTransportValuesAreNotCommandOrMultilineData() {
        XCTAssertNil(ADBParser.hardwareSerial("serial\nsecret"))
        XCTAssertNil(ADBParser.hardwareSerial("unknown"))
        XCTAssertNil(ADBParser.hardwareSerial(""))
        XCTAssertFalse(ADBParser.validTransportID("-s"))
        XCTAssertFalse(ADBParser.validTransportID("x;id"))
        XCTAssertEqual(ADBParser.hardwareSerial("  ABC-123\n"), "ABC-123")
    }
}
