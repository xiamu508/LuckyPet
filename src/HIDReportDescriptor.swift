import Foundation

/// 最小的 HID Report Descriptor 解析：只提取 Feature report 的 ID 与字节长度。
/// 浏览器版驱动从 collection 里取第一个 featureReport 的 reportId，
/// macOS 侧没有直接读取该信息的 API，只能解析描述符。
enum HIDReportDescriptor {

    struct FeatureReport {
        let id: Int
        let byteSize: Int
    }

    static func featureReports(from data: Data) -> [FeatureReport] {
        let bytes = [UInt8](data)
        var reports: [FeatureReport] = []
        var reportID = 0
        var reportSize = 0
        var reportCount = 0
        var index = 0

        while index < bytes.count {
            let prefix = bytes[index]

            // Long item: 0xFE, bDataSize, bLongItemTag, data...
            if prefix == 0xFE {
                guard index + 2 < bytes.count else { break }
                let dataSize = Int(bytes[index + 1])
                index += 3 + dataSize
                continue
            }

            index += 1
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            let type = Int((prefix >> 2) & 0x03)
            let tag = Int((prefix >> 4) & 0x0F)
            let value = unsigned(bytes, at: index, size: size)

            switch (type, tag) {
            case (1, 7):  // Global / Report Size
                reportSize = value
            case (1, 8):  // Global / Report ID
                reportID = value
            case (1, 9):  // Global / Report Count
                reportCount = value
            case (0, 11): // Main / Feature
                let byteSize = (reportSize * reportCount) / 8
                reports.append(FeatureReport(id: reportID, byteSize: byteSize))
            default:
                break
            }

            index += size
        }

        return reports
    }

    /// 选出用于厂商命令的那个 Feature report：优先 64 字节（65 字节含 ID）的报文。
    static func preferredFeatureReport(from data: Data?) -> FeatureReport {
        guard let data, !data.isEmpty else {
            return FeatureReport(id: 0, byteSize: 64)
        }
        let reports = featureReports(from: data)
        guard !reports.isEmpty else {
            return FeatureReport(id: 0, byteSize: 64)
        }
        if let big = reports.filter({ $0.byteSize >= 64 }).max(by: { $0.byteSize < $1.byteSize }) {
            return big
        }
        return reports[0]
    }

    private static func unsigned(_ bytes: [UInt8], at offset: Int, size: Int) -> Int {
        guard size > 0, offset >= 0, offset + size <= bytes.count else { return 0 }
        var value = 0
        for k in 0..<size {
            value |= Int(bytes[offset + k]) << (8 * k)
        }
        return value
    }
}
