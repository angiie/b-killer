import Foundation
import IOKit
import IOKit.ps

/// 电池与电源的瞬时状态快照
struct BatterySnapshot {
    /// 电量百分比（0-100）
    var level: Int
    /// 当前是否由外部电源供电（适配器被切断时为 false）
    var isPluggedIn: Bool
    /// 是否正在充电
    var isCharging: Bool
    /// 电池循环次数，读取失败时为 nil
    var cycleCount: Int?
    /// 电池健康度（0-100：满容量占设计容量的比例），读取失败时为 nil
    var healthPercent: Int?
}

/// 通过 IOKit 电源管理接口读取内置电池状态
enum BatteryMonitor {

    /// 读取一次电池状态快照，失败时返回 nil
    static func snapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        let detail = batteryDetail()

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
                isCharging: info[kIOPSIsChargingKey] as? Bool ?? false,
                cycleCount: detail.cycleCount,
                healthPercent: detail.healthPercent
            )
        }
        return nil
    }

    /// 从 AppleSmartBattery 读取循环次数与健康度
    ///
    /// 电量与供电状态走 IOPS（口径与系统一致），但循环次数和设计/满容量只存在于
    /// AppleSmartBattery 的注册表属性里，所以这里单独读一次。
    ///
    /// 容量键的位置随 macOS 版本变化：Intel 与旧版本把 `MaxCapacity` / `DesignCapacity`
    /// 放在顶层且单位是 mAh，新版本放在 `BatteryData` 字典里，顶层 `MaxCapacity`
    /// 退化成 100 的百分比。因此按「原始满容量 → 大于 100 的顶层 MaxCapacity →
    /// 标称满容量 → 满充容量」的顺序挑选，跳过百分比口径的值，避免算出离谱的健康度。
    private static func batteryDetail() -> (cycleCount: Int?, healthPercent: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any]
        else { return (nil, nil) }

        let cycleCount = (properties["CycleCount"] as? Int).map { max(0, $0) }
        // 新版本把容量明细放在 BatteryData 里，取不到就退回顶层键
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]

        let designCapacity = positiveValue(batteryData["DesignCapacity"])
            ?? positiveValue(properties["DesignCapacity"])
        // 候选按优先级排列：原始满容量是系统电池健康页最接近的口径，
        // 顶层 MaxCapacity 只有大于 100 才说明单位是 mAh，否则是百分比。
        let fullCapacity = [
            positiveValue(properties["AppleRawMaxCapacity"]),
            positiveValue(properties["MaxCapacity"]).flatMap { $0 > 100 ? $0 : nil },
            positiveValue(batteryData["NominalChargeCapacity"]),
            positiveValue(properties["NominalChargeCapacity"]),
            positiveValue(batteryData["FullChargeCapacity"])
        ].compactMap { $0 }.first

        guard let designCapacity, designCapacity > 0,
              let fullCapacity
        else { return (cycleCount, nil) }

        let ratio = Double(fullCapacity) / Double(designCapacity)
        // 单位不一致或读数异常时宁可不显示，也不要给出错误健康度
        guard ratio > 0.2, ratio <= 1.5 else { return (cycleCount, nil) }

        let health = min(100, max(0, Int((ratio * 100).rounded())))
        return (cycleCount, health)
    }

    /// 把注册表里的数值转成大于 0 的 Int，无效值返回 nil
    private static func positiveValue(_ value: Any?) -> Int? {
        guard let number = value as? Int, number > 0 else { return nil }
        return number
    }
}
