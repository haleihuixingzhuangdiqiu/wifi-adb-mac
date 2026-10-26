import Foundation
import Darwin

public enum ADBError: Error, LocalizedError, Equatable {
    case invalidEndpoint, invalidPort, invalidCode, unavailable, timeout, commandFailed, outputLimit
    case pairingFailed, ambiguous, identityUnavailable, identityMismatch, notConnected, busy
    case storageRead, storageWrite, addressRequired

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "请输入有效的 IP 或主机名，不要包含空格、协议或命令字符。"
        case .invalidPort: return "端口必须是 1–65535 之间的整数。"
        case .invalidCode: return "请输入手机显示的六位数字配对码。"
        case .unavailable: return "找不到可执行的 adb，请在设置中选择本机的 platform-tools/adb。"
        case .timeout: return "操作超时。请检查设备的无线调试和网络后重试。"
        case .commandFailed: return "adb 未能完成操作。请检查无线调试、连接端口和设备授权。"
        case .outputLimit: return "adb 返回的数据过多，已停止读取结果。请检查 adb 路径。"
        case .pairingFailed: return "配对未完成。请重新打开手机的配对窗口，使用最新端口和配对码重试。"
        case .ambiguous: return "发现多个可能的连接地址，已停止自动连接。请手动输入手机当前的连接地址。"
        case .identityUnavailable: return "无法验证硬件序列号，尚未确认重连成功。请通过添加设备手动连接并重新绑定。"
        case .identityMismatch: return "该地址上的设备与保存的设备不一致，未更改原记录。请手动核对连接地址。"
        case .notConnected: return "设备尚未在线。请确认使用的是无线调试主页上的连接端口。"
        case .busy: return "另一项操作正在进行，请稍候。"
        case .storageRead: return "无法读取本地记录。原文件已保留；请检查数据目录中的 JSON 文件后重新启动。"
        case .storageWrite: return "无法保存本地记录。请检查数据目录权限和剩余空间。"
        case .addressRequired: return "该无线连接当前没有可用地址，暂时无法保存。请打开手机的无线调试页面，通过添加设备输入当前连接地址后保存。"
        }
    }
}

public struct Endpoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int

    public init(host input: String, port: Int) throws {
        guard (1...65535).contains(port) else { throw ADBError.invalidPort }
        var host = input
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ $0.isASCII }),
              !host.contains(where: { $0.isWhitespace }) else { throw ADBError.invalidEndpoint }
        if host.contains(":") {
            let scoped = host.split(separator: "%", omittingEmptySubsequences: false)
            guard scoped.count <= 2 else { throw ADBError.invalidEndpoint }
            let addressText = String(scoped[0])
            let scope = scoped.count == 2 ? String(scoped[1]) : nil
            if let scope {
                guard !scope.isEmpty, scope.count <= 32,
                      scope.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw ADBError.invalidEndpoint }
            }
            var address = in6_addr()
            guard addressText.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw ADBError.invalidEndpoint }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN))
            host = String(cString: buffer) + (scope.map { "%" + $0 } ?? "")
        } else {
            let labels = (host.hasSuffix(".") ? String(host.dropLast()) : host).split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, labels.allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            }) else { throw ADBError.invalidEndpoint }
            // Numeric dotted hosts must be genuine IPv4 addresses, not misleading DNS names.
            if host.allSatisfy({ $0.isNumber || $0 == "." }) {
                var address = in_addr()
                guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { throw ADBError.invalidEndpoint }
            }
            host = host.lowercased()
        }
        self.host = host
        self.port = port
    }

    public init(host: String, portText: String) throws {
        guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(portText) else { throw ADBError.invalidPort }
        try self.init(host: host, port: port)
    }

    public init(_ text: String) throws {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]"), text.index(after: close) < text.endIndex,
           text[text.index(after: close)] == ":" {
            try self.init(host: String(text[...close]), portText: String(text[text.index(close, offsetBy: 2)...]))
        } else {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw ADBError.invalidEndpoint }
            try self.init(host: String(pieces[0]), portText: String(pieces[1]))
        }
    }

    public var description: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    enum CodingKeys: String, CodingKey { case host, port }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: values.decode(String.self, forKey: .host), port: values.decode(Int.self, forKey: .port))
    }
}

public enum TransportState: String, Codable, Sendable { case device, offline, unauthorized, unknown }

public struct ADBTransport: Identifiable, Equatable, Sendable {
    public let id: String
    public let state: TransportState
    public let model: String?
    public let usb: Bool
    public var endpoint: Endpoint? { try? Endpoint(id) }
    public var isWireless: Bool {
        !usb && (endpoint != nil || id.hasSuffix("._adb-tls-connect._tcp") || id.hasSuffix("._adb-tls-connect._tcp."))
    }
    public var isEmulator: Bool { id.hasPrefix("emulator-") }
    public var displayName: String { model?.replacingOccurrences(of: "_", with: " ") ?? (isEmulator ? "Android 模拟器" : "Android 设备") }
}

public struct MDNSService: Identifiable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let endpoint: Endpoint
    public var id: String { "\(name)|\(type)|\(endpoint)" }
    public var isConnect: Bool { type == "_adb-tls-connect._tcp" }
    public var transportName: String { "\(name)\(name.hasSuffix(".") ? "" : ".")\(type)" }
    public func matches(serial: String) -> Bool { name.hasPrefix("adb-\(serial)-") }
    public func matches(transport: ADBTransport) -> Bool {
        transport.endpoint == endpoint || transport.id == transportName || transport.id == transportName + "."
    }
}

public struct SavedDevice: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let hardwareSerial: String
    public var mdnsIdentity: String?
    public var lastEndpoint: Endpoint
    public var lastConnected: Date

    public init(id: UUID = UUID(), name: String, hardwareSerial: String, mdnsIdentity: String? = nil, lastEndpoint: Endpoint, lastConnected: Date = Date()) {
        self.id = id; self.name = name; self.hardwareSerial = hardwareSerial
        self.mdnsIdentity = mdnsIdentity; self.lastEndpoint = lastEndpoint; self.lastConnected = lastConnected
    }
}

public struct DiscoverySnapshot: Sendable {
    public var transports: [ADBTransport]
    public var services: [MDNSService]
    public var discoveryAvailable: Bool
    public init(transports: [ADBTransport] = [], services: [MDNSService] = [], discoveryAvailable: Bool = true) {
        self.transports = transports; self.services = services; self.discoveryAvailable = discoveryAvailable
    }
}

public enum ReconnectResolver {
    public static func endpoint(for device: SavedDevice, services: [MDNSService]) throws -> Endpoint {
        // A previously verified, hardware-bound service is more specific than
        // stale advertisements for the same phone under other instance names.
        let remembered = services.filter { $0.isConnect && $0.name == device.mdnsIdentity && $0.matches(serial: device.hardwareSerial) }
        if !remembered.isEmpty {
            let endpoints = Set(remembered.map(\.endpoint))
            guard endpoints.count == 1, let endpoint = endpoints.first else { throw ADBError.ambiguous }
            return endpoint // The coordinator still verifies the hardware after connection.
        }
        let matching = services.filter { $0.isConnect && ($0.matches(serial: device.hardwareSerial) || $0.name == device.mdnsIdentity) }
        let endpoints = Set(matching.map(\.endpoint))
        guard endpoints.count <= 1 else { throw ADBError.ambiguous }
        return endpoints.first ?? device.lastEndpoint
    }
}
