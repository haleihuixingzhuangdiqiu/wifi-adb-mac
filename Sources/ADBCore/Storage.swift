import Foundation

public struct DeviceStorage: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("devices.json") }
    private struct Document: Codable { let version: Int; let devices: [SavedDevice] }

    public init(directory: URL = DeviceStorage.defaultDirectory) { self.directory = directory }
    public static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["WIFIADB_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WiFiADB", isDirectory: true)
    }

    public func load() throws -> [SavedDevice] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 2 * 1024 * 1024 else { throw ADBError.storageRead }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, document.devices.count <= 1000,
                  Set(document.devices.map(\.id)).count == document.devices.count,
                  Set(document.devices.map(\.hardwareSerial)).count == document.devices.count,
                  document.devices.allSatisfy({ ADBParser.hardwareSerial($0.hardwareSerial) == $0.hardwareSerial && !$0.name.isEmpty && $0.name.count <= 120 })
            else { throw ADBError.storageRead }
            return document.devices
        } catch { throw ADBError.storageRead }
    }

    public func save(_ devices: [SavedDevice]) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(version: 1, devices: devices)).write(to: fileURL, options: .atomic)
        } catch { throw ADBError.storageWrite }
    }
}

public enum ADBLocation {
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["WIFIADB_ADB_PATH"] { return URL(fileURLWithPath: override) }
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
                     "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}
