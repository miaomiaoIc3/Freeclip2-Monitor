import Foundation

/// 盒盖状态（来自 FDEE 广播字节[2]）
enum LidState: String, Codable {
    case open = "开盖"
    case closed = "合盖"
    case unknown = "未知"
}

/// 数据来源通道
enum TelemetrySource: String, Codable {
    case fdeeBroadcast = "FDEE 广播"
    case fd21Gatt = "FD21 连接"
}

/// 单项电池快照（充电盒 / 左耳 / 右耳）
struct BatteryUnit: Codable, Equatable {
    /// 0~100；nil 表示当前未上报（例如单耳不在盒内）
    let level: Int?
    let isCharging: Bool

    var displayText: String {
        guard let level else { return "--" }
        return isCharging ? "\(level)%⚡" : "\(level)%"
    }

    var shortPercent: String {
        guard let level else { return "--" }
        return "\(level)%"
    }
}

/// FreeClip 2 完整真实电量快照
struct FreeClipSnapshot: Codable, Equatable {
    let caseBattery: BatteryUnit
    let earbud1: BatteryUnit
    let earbud2: BatteryUnit
    let lidState: LidState
    let source: TelemetrySource
    let timestamp: Date
    let rawHex: String

    /// 摘要文案（用于通知与快捷指令返回值）
    var summaryLine: String {
        let caseText = (caseBattery.isCharging && (caseBattery.level ?? 100) < 100)
            ? "\(caseBattery.shortPercent)⚡"
            : caseBattery.shortPercent
        return "充电盒 \(caseText) · 左耳 \(earbud1.shortPercent) · 右耳 \(earbud2.shortPercent)"
    }

    /// 电量、充电或盒盖状态是否相对上次有实质变化
    func hasSignificantChange(comparedTo other: FreeClipSnapshot?) -> Bool {
        guard let other else { return true }
        return caseBattery != other.caseBattery
            || earbud1 != other.earbud1
            || earbud2 != other.earbud2
            || lidState != other.lidState
    }

    /// 充电盒是否处于低电状态
    func isCaseLow(threshold: Int) -> Bool {
        guard let lvl = caseBattery.level else { return false }
        return lvl <= threshold && !caseBattery.isCharging
    }
}

/// 用户偏好配置
struct MonitorSettings: Codable, Equatable {
    /// 每次断开/触发扫描都推送通知（符合“每次断开都推”的需求）
    var notifyOnEveryScan: Bool = true
    /// 充电盒低电醒目标记阈值（%）
    var lowBatteryThreshold: Int = 20
    /// 充电盒充满 100% 时推送通知
    var notifyWhenFull: Bool = true
    /// 上一次已保存的 FreeClip 2 CoreBluetooth Peripheral UUID 字符串
    var savedPeripheralUUID: String? = nil
}

/// 华为 FreeClip 2 双通道协议解析器（FDEE 广播 + FD21 GATT 串口帧）
enum FreeClipProtocol {
    // 华为 BLE Service Data UUID（广播状态帧）
    static let fdeeUUIDString = "FDEE"
    // 华为可发现/配对相关 UUID
    static let fd9aUUIDString = "FD9A"
    // 华为音频 GATT 服务及透传特征值 UUID（已实测抓取）
    static let fd21ServiceUUIDString = "FD21"
    static let fd21NotifyCharUUIDString = "02000200-0000-2000-8000-009E78563412"
    static let fd21WriteCharUUIDString = "03000300-0000-3000-8000-009E78563412"

    // 查电量指令帧：5A 00 03 00 01 08 + CRC16-XMODEM (DF 73)
    static let queryBatteryFrame = Data([0x5A, 0x00, 0x03, 0x00, 0x01, 0x08, 0xDF, 0x73])

    // ------------------------------------------------------------------------
    // 通道 A：解析 FDEE 广播 Service Data
    //
    // 已通过真机对照实测验证的 3 组原始报文：
    //   开盖未插线: 01 02 03 FF 0C 00 00 01 67 01 03 8A AB 64 E4 E4 F2 90
    //   合盖插线充: 01 02 00 FF 08 00 00 01 67 01 03 4C AB E4 E4 E4 80
    //   合盖未插线: 01 02 00 FF 08 00 00 01 67 01 03 4C AB 64 E4 E4 80
    //
    // 字节含义：
    //   [0..1]  01 02       状态广播帧头
    //   [2]     03 / 00     盒盖状态（03=开盖，00=合盖）
    //   [3]     FF          状态标识
    //   [5..8]  00 00 01 67 FreeClip 2 型号 ID
    //   [9..10] 01 03       3 路电量数据标记
    //   [13]    充电盒电量  (bit7=是否充电, bit0..6=电量 0~100)
    //   [14]    耳机 1 电量 (bit7=是否充电, bit0..6=电量 0~100)
    //   [15]    耳机 2 电量 (bit7=是否充电, bit0..6=电量 0~100)
    // ------------------------------------------------------------------------
    static func parseFDEE(_ data: Data, now: Date = Date()) -> FreeClipSnapshot? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return nil }

        // 过滤掉 00 10 00 01... 可连接发现帧，只解析 01 02 ... FF 状态电量帧
        guard bytes[0] == 0x01, bytes[1] == 0x02, bytes[3] == 0xFF else {
            return nil
        }

        // 校验型号段（00 00 01 67）或电池标记段（01 03）
        let isFreeClip2Model = bytes[5] == 0x00 && bytes[6] == 0x00 && bytes[7] == 0x01 && bytes[8] == 0x67
        let hasBatteryMarker = bytes[9] == 0x01 && bytes[10] == 0x03
        guard isFreeClip2Model || hasBatteryMarker else {
            return nil
        }

        let lidState: LidState
        switch bytes[2] {
        case 0x03: lidState = .open
        case 0x00: lidState = .closed
        default: lidState = .unknown
        }

        let caseUnit = decodeBatteryByte(bytes[13])
        let bud1Unit = decodeBatteryByte(bytes[14])
        let bud2Unit = decodeBatteryByte(bytes[15])

        // 至少有一项有效电量才视为有效报文
        guard caseUnit.level != nil || bud1Unit.level != nil || bud2Unit.level != nil else {
            return nil
        }

        return FreeClipSnapshot(
            caseBattery: caseUnit,
            earbud1: bud1Unit,
            earbud2: bud2Unit,
            lidState: lidState,
            source: .fdeeBroadcast,
            timestamp: now,
            rawHex: data.hexString
        )
    }

    private static func decodeBatteryByte(_ byte: UInt8) -> BatteryUnit {
        let isCharging = (byte & 0x80) != 0
        let rawLevel = Int(byte & 0x7F)
        // 华为协议中 0x7F (127) 或 >100 表示设备不在盒/未上报
        let level: Int? = (rawLevel <= 100) ? rawLevel : nil
        return BatteryUnit(level: level, isCharging: isCharging)
    }

    // ------------------------------------------------------------------------
    // 通道 B：解析 FD21 GATT 串口回包（5A 帧：01 08 查电量 / 01 27 电量推送）
    //
    // 帧格式: 5A <len:2BE> 00 <cmd:2> <TLVs...> <crc16_xmodem:2BE>
    // TLV Tag 0x02 (len=3): [left, right, case] 电量
    // TLV Tag 0x03 (len=3): [leftChg, rightChg, caseChg] 充电状态
    // ------------------------------------------------------------------------
    static func parseFD21Frame(_ data: Data, now: Date = Date()) -> FreeClipSnapshot? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0] == 0x5A else { return nil }

        let payloadLen = (Int(bytes[1]) << 8) | Int(bytes[2])
        let expectedTotal = 3 + payloadLen + 2
        guard bytes.count >= expectedTotal else { return nil }

        // 校验 CRC16-XMODEM
        let frameBody = Array(bytes[0..<(3 + payloadLen)])
        let receivedCRC = (UInt16(bytes[3 + payloadLen]) << 8) | UInt16(bytes[3 + payloadLen + 1])
        guard crc16XMODEM(frameBody) == receivedCRC else { return nil }

        // cmd 位于 bytes[4..5]：01 08 (查询响应) 或 01 27 (主动上报)
        let cmdHi = bytes[4]
        let cmdLo = bytes[5]
        guard cmdHi == 0x01, (cmdLo == 0x08 || cmdLo == 0x27) else { return nil }

        var levels: [UInt8]? = nil
        var charging: [UInt8]? = nil
        var globalLevel: UInt8? = nil

        var idx = 6
        let tlvEnd = 3 + payloadLen
        while idx + 2 <= tlvEnd {
            let tag = bytes[idx]
            let len = Int(bytes[idx + 1])
            idx += 2
            guard idx + len <= tlvEnd else { break }
            let val = Array(bytes[idx..<(idx + len)])
            idx += len

            switch tag {
            case 0x01 where len >= 1:
                globalLevel = val[0]
            case 0x02 where len >= 3:
                levels = val
            case 0x03 where len >= 3:
                charging = val
            default:
                break
            }
        }

        if let levels {
            let leftLvl: Int? = levels[0] <= 100 ? Int(levels[0]) : nil
            let rightLvl: Int? = levels[1] <= 100 ? Int(levels[1]) : nil
            let caseLvl: Int? = levels[2] <= 100 ? Int(levels[2]) : nil

            let leftChg = (charging != nil && charging!.count >= 1) ? charging![0] != 0 : false
            let rightChg = (charging != nil && charging!.count >= 2) ? charging![1] != 0 : false
            let caseChg = (charging != nil && charging!.count >= 3) ? charging![2] != 0 : false

            return FreeClipSnapshot(
                caseBattery: BatteryUnit(level: caseLvl, isCharging: caseChg),
                earbud1: BatteryUnit(level: leftLvl, isCharging: leftChg),
                earbud2: BatteryUnit(level: rightLvl, isCharging: rightChg),
                lidState: .unknown,
                source: .fd21Gatt,
                timestamp: now,
                rawHex: data.hexString
            )
        }

        if let globalLevel, globalLevel <= 100 {
            let u = BatteryUnit(level: Int(globalLevel), isCharging: false)
            return FreeClipSnapshot(
                caseBattery: BatteryUnit(level: nil, isCharging: false),
                earbud1: u,
                earbud2: u,
                lidState: .unknown,
                source: .fd21Gatt,
                timestamp: now,
                rawHex: data.hexString
            )
        }

        return nil
    }

    static func crc16XMODEM(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0x0000
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
