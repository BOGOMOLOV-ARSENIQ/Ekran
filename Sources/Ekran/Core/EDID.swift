import Foundation

/// Decoder for the EDID base block and the CTA-861 extension (enough to explain what a monitor advertises).
struct EDID {
    struct Timing {
        var width: Int
        var height: Int
        var refreshRate: Double
        var interlaced: Bool
    }

    let raw: Data
    private(set) var manufacturer = "???"
    private(set) var productCode: UInt16 = 0
    private(set) var serialNumber: UInt32 = 0
    private(set) var week = 0
    private(set) var year = 0
    private(set) var version = ""
    private(set) var isDigital = false
    private(set) var bitDepth: Int?
    private(set) var interface: String?
    private(set) var sizeCentimeters = (width: 0, height: 0)
    private(set) var gamma = 0.0
    private(set) var chromaticity: [String: (x: Double, y: Double)] = [:]
    private(set) var name: String?
    private(set) var serialText: String?
    private(set) var rangeLimits: String?
    private(set) var timings: [Timing] = []
    private(set) var extensionCount = 0
    private(set) var checksumValid = false
    // CTA-861
    private(set) var hasCTA = false
    private(set) var hasDisplayID = false
    private(set) var ycbcr444 = false
    private(set) var ycbcr422 = false
    private(set) var ycbcr420 = false
    private(set) var basicAudio = false
    private(set) var hdmi = false
    private(set) var hdmiForum = false
    private(set) var hdrTransferFunctions: [String] = []
    private(set) var hdrMaxLuminance: Double?
    private(set) var hdrMinLuminance: Double?
    private(set) var bt2020 = false
    private(set) var videoCodes: [Int] = []

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 128, bytes[0 ..< 8].elementsEqual([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]) else { return nil }
        raw = data
        parseBase(bytes)
        var offset = 128
        while offset + 128 <= bytes.count {
            let block = Array(bytes[offset ..< offset + 128])
            switch block[0] {
            case 0x02: parseCTA(block)
            case 0x70: hasDisplayID = true
            default: break
            }
            offset += 128
        }
    }

    private mutating func parseBase(_ b: [UInt8]) {
        let id = UInt16(b[8]) << 8 | UInt16(b[9])
        manufacturer = String([(id >> 10) & 0x1F, (id >> 5) & 0x1F, id & 0x1F].map { Character(UnicodeScalar(UInt8($0) + 64)) })
        productCode = UInt16(b[10]) | UInt16(b[11]) << 8
        serialNumber = UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
        week = Int(b[16])
        year = Int(b[17]) + 1980
        version = "\(b[18]).\(b[19])"
        isDigital = b[20] & 0x80 != 0
        if isDigital {
            let depths = [0: nil, 1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16] as [Int: Int?]
            bitDepth = depths[Int((b[20] >> 4) & 0x7)] ?? nil
            interface = [1: "DVI", 2: "HDMI-a", 3: "HDMI-b", 4: "MDDI", 5: "DisplayPort"][Int(b[20] & 0x0F)]
        }
        sizeCentimeters = (Int(b[21]), Int(b[22]))
        gamma = b[23] == 0xFF ? 0 : (Double(b[23]) + 100) / 100

        func coordinate(_ high: UInt8, _ low: UInt8, _ shift: UInt8) -> Double {
            Double(Int(high) << 2 | Int((low >> shift) & 0x3)) / 1024
        }
        chromaticity = [
            "red": (coordinate(b[27], b[25], 6), coordinate(b[28], b[25], 4)),
            "green": (coordinate(b[29], b[25], 2), coordinate(b[30], b[25], 0)),
            "blue": (coordinate(b[31], b[26], 6), coordinate(b[32], b[26], 4)),
            "white": (coordinate(b[33], b[26], 2), coordinate(b[34], b[26], 0)),
        ]

        for index in 0 ..< 4 {
            let d = Array(b[(54 + index * 18) ..< (72 + index * 18)])
            if d[0] != 0 || d[1] != 0 {
                if let timing = Self.detailedTiming(d) { timings.append(timing) }
                continue
            }
            let text = String(bytes: d[5 ..< 18].prefix { $0 != 0x0A }, encoding: .ascii)?.trimmedDisplayName
            switch d[3] {
            case 0xFC: name = text
            case 0xFF: serialText = text
            case 0xFD:
                let minV = Int(d[5]) + ((d[4] & 0x03) == 0x03 ? 255 : 0)
                let maxV = Int(d[6]) + ((d[4] & 0x02) != 0 ? 255 : 0)
                let minH = Int(d[7]) + ((d[4] & 0x0C) == 0x0C ? 255 : 0)
                let maxH = Int(d[8]) + ((d[4] & 0x08) != 0 ? 255 : 0)
                rangeLimits = "\(minV)–\(maxV) Гц по вертикали, \(minH)–\(maxH) кГц, до \(Int(d[9]) * 10) МГц"
            default: break
            }
        }
        extensionCount = Int(b[126])
        checksumValid = b[0 ..< 128].reduce(UInt8(0)) { $0 &+ $1 } == 0
    }

    private static func detailedTiming(_ d: [UInt8]) -> Timing? {
        let clock = Double(Int(d[0]) | Int(d[1]) << 8) * 10_000
        let hActive = Int(d[2]) | Int(d[4] >> 4) << 8
        let hBlank = Int(d[3]) | Int(d[4] & 0x0F) << 8
        let vActive = Int(d[5]) | Int(d[7] >> 4) << 8
        let vBlank = Int(d[6]) | Int(d[7] & 0x0F) << 8
        let total = Double((hActive + hBlank) * (vActive + vBlank))
        guard hActive > 0, vActive > 0, total > 0 else { return nil }
        return Timing(width: hActive, height: vActive, refreshRate: clock / total, interlaced: d[17] & 0x80 != 0)
    }

    private mutating func parseCTA(_ b: [UInt8]) {
        hasCTA = true
        let dtdOffset = Int(b[2])
        basicAudio = b[3] & 0x40 != 0
        ycbcr444 = b[3] & 0x20 != 0
        ycbcr422 = b[3] & 0x10 != 0

        var i = 4
        while i < min(dtdOffset, 127) {
            let tag = b[i] >> 5
            let length = Int(b[i] & 0x1F)
            guard i + length < 128 else { break }
            let payload = Array(b[(i + 1) ..< (i + 1 + length)])
            switch tag {
            case 2:
                videoCodes += payload.map { Int($0 & 0x7F) }
            case 3 where payload.count >= 3:
                let oui = Int(payload[0]) | Int(payload[1]) << 8 | Int(payload[2]) << 16
                if oui == 0x000C03 { hdmi = true }
                if oui == 0xC45DD8 { hdmiForum = true }
            case 7 where !payload.isEmpty:
                switch payload[0] {
                case 0x06 where payload.count >= 2:
                    let names = ["SDR", "HDR (гамма)", "PQ / HDR10", "HLG"]
                    hdrTransferFunctions = names.enumerated().filter { Int(payload[1]) & (1 << $0.offset) != 0 }.map(\.element)
                    if payload.count >= 4, payload[3] > 0 { hdrMaxLuminance = 50 * pow(2, Double(payload[3]) / 32) }
                    if payload.count >= 6, let max = hdrMaxLuminance {
                        hdrMinLuminance = max * pow(Double(payload[5]) / 255, 2) / 100
                    }
                case 0x05 where payload.count >= 2:
                    bt2020 = payload[1] & 0xE0 != 0
                case 0x0E, 0x0F:
                    ycbcr420 = true
                default: break
                }
            default: break
            }
            i += length + 1
        }

        var offset = dtdOffset
        while dtdOffset >= 4, offset + 18 <= 127 {
            let d = Array(b[offset ..< offset + 18])
            if d[0] == 0 && d[1] == 0 { break }
            if let timing = Self.detailedTiming(d) { timings.append(timing) }
            offset += 18
        }
    }

    /// Human readable summary for the info window.
    var summary: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("Производитель", manufacturer))
        if let name { rows.append(("Модель", name)) }
        rows.append(("Код продукта", String(format: "0x%04X", productCode)))
        rows.append(("Серийный номер", serialText ?? (serialNumber == 0 ? "—" : String(serialNumber))))
        rows.append(("Дата выпуска", week == 0xFF ? "модель \(year) г." : "неделя \(week), \(year) г."))
        rows.append(("Версия EDID", version + (checksumValid ? "" : " (ошибка контрольной суммы)")))
        rows.append(("Вход", isDigital ? "цифровой" + (interface.map { ", \($0)" } ?? "") + (bitDepth.map { ", \($0) бит" } ?? "") : "аналоговый"))
        if sizeCentimeters.width > 0 {
            let inches = (Double(sizeCentimeters.width * sizeCentimeters.width + sizeCentimeters.height * sizeCentimeters.height)).squareRoot() / 2.54
            rows.append(("Размер", "\(sizeCentimeters.width)×\(sizeCentimeters.height) см (≈\(Int(inches.rounded()))″)"))
        }
        if gamma > 0 { rows.append(("Гамма", String(format: "%.2f", gamma))) }
        for key in ["red", "green", "blue", "white"] {
            if let point = chromaticity[key] {
                let title = ["red": "Красный", "green": "Зелёный", "blue": "Синий", "white": "Белая точка"][key]!
                rows.append((title, String(format: "x %.4f  y %.4f", point.x, point.y)))
            }
        }
        for (index, timing) in timings.enumerated() {
            rows.append((index == 0 ? "Родной режим" : "Режим \(index + 1)",
                         String(format: "%d×%d @ %.2f Гц%@", timing.width, timing.height, timing.refreshRate, timing.interlaced ? " (i)" : "")))
        }
        if let rangeLimits { rows.append(("Диапазон", rangeLimits)) }
        rows.append(("Расширения", extensionCount == 0 ? "нет" : [hasCTA ? "CTA-861" : nil, hasDisplayID ? "DisplayID" : nil].compactMap { $0 }.joined(separator: ", ")))
        if hasCTA {
            rows.append(("HDMI", hdmiForum ? "HDMI 2.x" : hdmi ? "HDMI 1.x" : "нет"))
            let formats = ["RGB", ycbcr444 ? "YCbCr 4:4:4" : nil, ycbcr422 ? "YCbCr 4:2:2" : nil, ycbcr420 ? "YCbCr 4:2:0" : nil].compactMap { $0 }
            rows.append(("Цветовые форматы", formats.joined(separator: ", ")))
            rows.append(("Аудио", basicAudio ? "да" : "нет"))
            if !hdrTransferFunctions.isEmpty { rows.append(("HDR", hdrTransferFunctions.joined(separator: ", "))) }
            if let hdrMaxLuminance { rows.append(("Пиковая яркость", "\(Int(hdrMaxLuminance)) кд/м²")) }
            if let hdrMinLuminance { rows.append(("Мин. яркость", String(format: "%.3f кд/м²", hdrMinLuminance))) }
            if bt2020 { rows.append(("Колориметрия", "BT.2020")) }
        }
        return rows
    }

    var hexDump: String {
        stride(from: 0, to: raw.count, by: 16).map { start in
            let line = raw[start ..< min(start + 16, raw.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
            return String(format: "%04X  ", start) + line
        }.joined(separator: "\n")
    }
}
