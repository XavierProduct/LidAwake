import Foundation

/// 一个电源分支（电池或接电）的 pmset 计时器设置。
/// 单位均为分钟，0 表示“永不”。
struct PowerBranch: Decodable {
    var displaysleep: Int?
    var sleep: Int?
    var disksleep: Int?
    var womp: Int?

    func text() -> String {
        "屏幕 \(fmt(displaysleep)) / 睡眠 \(fmt(sleep))"
    }

    private func fmt(_ v: Int?) -> String {
        guard let v = v else { return "?" }
        return v == 0 ? "永不" : "\(v) 分"
    }
}

/// USB PD 档位菜单里的一项。
struct PDMenu: Decodable {
    var voltage: Int
    var current: Int

    /// 后端返回的是 [电压mV, 电流mA] 的二元数组。
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        voltage = try c.decode(Int.self)
        current = try c.decode(Int.self)
    }

    var watts: Double { Double(voltage) / 1000.0 * Double(current) / 1000.0 }
    var voltageText: String { String(format: "%.0fV", Double(voltage) / 1000.0) }
    var wattsText: String { String(format: "%.1fW", watts) }
}

/// 适配器信息。
struct Adapter: Decodable {
    var watts: Int?
    var voltage: Int?
    var current: Int?
    var menu: [PDMenu]
    var has_20v: Bool

    var negotiatedWatts: Double? {
        guard let v = voltage, let c = current else { return nil }
        return Double(v) / 1000.0 * Double(c) / 1000.0
    }

    var summary: String {
        guard let w = watts else { return "未检测到适配器" }
        guard let n = negotiatedWatts else { return "标称 \(w) W" }
        return String(format: "标称 %d W · 协商 %.1f W", w, n)
    }
}

/// `batteryctl.py status --json` 的完整结构。
struct StatusPayload: Decodable {
    var battery: PowerBranch
    var ac: PowerBranch
    var global: [String: Int]
    var power_source: String?
    var battery_state: String?
    var soc_percent: Int?
    var profiles: [String]
    var external_displays: Int
    var screen_recording: Bool
    var adapter: Adapter?

    var sleepDisabled: Bool { (global["SleepDisabled"] ?? 0) == 1 }

    var powerSourceText: String {
        power_source == "AC" ? "接电" : "电池"
    }

    var batteryStateText: String {
        guard let s = battery_state else { return "" }
        switch s {
        case "charging": return "充电中"
        case "discharging": return "放电中"
        case "AC attached": return "已接电，未充电"
        case "charged": return "已充满"
        default: return s
        }
    }

    /// 根据当前设置反推正在生效的模式名。
    func currentProfileName() -> String? {
        for name in profiles {
            guard let p = ProfileCatalog.shared.profiles[name] else { continue }
            let sameBattery = p.battery.displaysleep == battery.displaysleep
                && p.battery.sleep == battery.sleep
            let sameAC = p.ac.displaysleep == ac.displaysleep
                && p.ac.sleep == ac.sleep
            let sameGlobal = (p.global["disablesleep"] == 1) == sleepDisabled
            if sameBattery && sameAC && sameGlobal { return name }
        }
        return nil
    }
}

/// profiles/ 目录里的一个模式定义。
struct Profile: Decodable {
    var name: String
    var description: String
    var requires: [String]
    var warn: String?
    var global: [String: Int]
    var battery: PowerBranch
    var ac: PowerBranch
}
