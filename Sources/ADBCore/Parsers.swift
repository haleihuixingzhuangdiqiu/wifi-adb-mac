import Foundation

public enum ADBParser {
    public static func devices(_ output: String) -> [ADBTransport] {
        output.split(separator: "\n").compactMap { line in
            // Long listings use spaces as well as tabs. Only the state/metadata
            // boundary separates the identifier; spaces can belong to its name.
            guard !line.hasPrefix("*"), !line.hasPrefix("adb:"),
                  let parts = captures(#"^(.+?)[ \t]+(device|offline|unauthorized|recovery|sideload|bootloader|no permissions)(?:[ \t]+((?:usb|product|model|device|transport_id):.*))?[ \t]*$"#, in: String(line))
                    ?? captures(#"^(.+?)[ \t]+(no permissions)(?:[ \t]+(.*))?$"#, in: String(line)),
                  validTransportID(parts[0]) else { return nil }
            let fields = parts[2].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) }
            return ADBTransport(id: parts[0], state: TransportState(rawValue: parts[1]) ?? .unknown,
                                model: model, usb: fields.contains(where: { $0.hasPrefix("usb:") }))
        }
    }

    public static func mdns(_ output: String) -> [MDNSService] {
        var result: [MDNSService] = []
        for line in output.split(separator: "\n") {
            guard let parts = captures(#"^(.+?)[ \t]+(_adb-tls-connect\._tcp|_adb-tls-pairing\._tcp|_adb\._tcp)\.?[ \t]+([^ \t]+)[ \t]*$"#, in: String(line)),
                  let endpoint = try? Endpoint(parts[2]), validTransportID(parts[0]) else { continue }
            let service = MDNSService(name: parts[0], type: parts[1], endpoint: endpoint)
            if !result.contains(service) { result.append(service) }
        }
        return result
    }

    public static func validTransportID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("-") &&
        value.first != " " && value.last != " " &&
        value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:[]% ()".unicodeScalars.contains($0)) }
    }

    private static func captures(_ pattern: String, in line: String) -> [String]? {
        guard !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }),
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    public static func hardwareSerial(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128, value != "unknown", value != "null",
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
        return value
    }
}
