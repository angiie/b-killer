import Foundation
import IOKit.ps

/// 电池与电源的瞬时状态快照
struct BatterySnapshot {
    /// 电量百分比（0-100）
    var level: Int
    /// 当前是否由外部电源供电（适配器被切断时为 false）
    var isPluggedIn: Bool
    /// 是否正在充电
    var isCharging: Bool
}

/// 通过 IOKit 电源管理接口读取内置电池状态
enum BatteryMonitor {

    /// 读取一次电池状态快照，失败时返回 nil
    static func snapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = info[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = info[kIOPSPowerSourceStateKey] as? String ?? ""

            // IOKit 返回的是原始容量，换算成百分比
            let level = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current

            return BatterySnapshot(
                level: level,
                isPluggedIn: state == kIOPSACPowerValue,
                isCharging: info[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }
}
