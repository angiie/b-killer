import Foundation
import IOKit.pwr_mgt

/// 循环所处阶段
enum CyclePhase {
    /// 未开启
    case idle
    /// 已通电，充电中，等待升到上限
    case charging
    /// 已切断墙上供电，电池放电中，等待降到下限
    case discharging
}

/// 充放电循环引擎：按滑杆设定的区间反复充放电
///
/// 上限处切断墙上供电使电池真实放电，下限处恢复供电重新充电。
/// 注意：本机固件（macOS 26 世代）只停充不断电时电流为 0、电量不会下降，
/// 因此必须切断适配器，否则区间循环无法成立。
final class CycleEngine: ObservableObject {

    /// 是否正在运行循环
    @Published private(set) var isRunning = false
    /// 当前阶段
    @Published private(set) var phase: CyclePhase = .idle
    /// 当前电量百分比
    @Published private(set) var level: Int = 0
    /// 是否由外部电源供电
    @Published private(set) var isPluggedIn = false
    /// 是否正在充电
    @Published private(set) var isCharging = false
    /// 错误提示，为空表示正常
    @Published private(set) var errorText: String? = nil
    /// 区间下限：降到这个电量就恢复供电
    @Published var lowThreshold: Int = 5
    /// 区间上限：升到这个电量就切断供电
    @Published var highThreshold: Int = 100

    /// 界面刷新间隔（秒）：只影响电量读数与状态的显示
    private let uiRefreshInterval: TimeInterval = 5
    /// 控制判定最小间隔（秒）：电量变化缓慢，无需频繁判断，半小时一次足够
    private let controlMinInterval: TimeInterval = 30 * 60
    /// 上次执行控制判定的时刻
    private var lastControlCheck = Date.distantPast
    /// 轮询定时器
    private var timer: Timer?
    /// 防睡眠断言 ID，0 表示未持有
    private var sleepAssertionID: IOPMAssertionID = 0

    /// 初始化：常驻轮询电量，保证未开启循环时界面也显示真实读数
    init() {
        refreshStatus()
        verifyAdapterSupport()
        startTimer()
    }

    /// 启动时确认本机硬件支持软件控制适配器
    ///
    /// 读 SMC 键元信息不需要 root，所以能在请求授权安装助手之前先做判断，
    /// 避免在不支持的机器上弹出无意义的授权对话框。
    private func verifyAdapterSupport() {
        guard !AdapterControl.isSupported() else { return }
        errorText = L10n.adapterUnsupported
    }

    /// 执行一次适配器开关
    /// - Parameters:
    ///   - enabled: true 接通墙上供电，false 切断改用电池
    ///   - interactive: 是否由用户直接触发；只有用户主动操作时才允许弹出授权安装对话框
    private func applyAdapter(enabled: Bool, interactive: Bool) throws {
        if !HelperClient.isReady() {
            // 后台循环里弹授权框会打断用户，因此只做提示不做安装
            guard interactive else { throw HelperError.notInstalled }
            try HelperClient.install()
        }
        try HelperClient.setAdapterEnabled(enabled)
    }

    /// 手动切换供电来源：当前用直流电源就切到电池，反之切回直流电源
    ///
    /// 与自动循环互斥：按下切换即终止正在运行的循环，
    /// 供电状态由本次切换决定，循环不会再用区间判定把它改回去。
    func switchPowerSource() {
        haltLoop()

        // 判定依据是当前供电状态：插着电说明正在用直流电源
        let switchToBattery = isPluggedIn
        do {
            try applyAdapter(enabled: !switchToBattery, interactive: true)
        } catch {
            errorText = error.localizedDescription
            refreshStatus()
            return
        }
        // IOPS 的供电标志有数秒刷新延迟，这里先按切换结果就地更新状态。
        // 否则连点两下时，第二次仍会读到旧的“已插电”，误判成再次切到电池。
        isPluggedIn = !switchToBattery
        if switchToBattery {
            isCharging = false
        }
        errorText = nil
    }

    /// 开启循环：先读一次电量，判断当前应该充电还是放电
    ///
    /// 与手动切换互斥：一旦开启，供电改由循环按区间接管，手动切换留下的状态被覆盖。
    func start() {
        guard !isRunning else { return }
        guard refreshStatus() else { return }
        let currentLevel = level

        do {
            if currentLevel >= highThreshold {
                // 已在上限之上：直接断电开始放电
                try applyAdapter(enabled: false, interactive: true)
                phase = .discharging
            } else {
                // 未到上限：确保供电正常开始充电（顺带清掉上次残留的断电状态）
                try applyAdapter(enabled: true, interactive: true)
                phase = .charging
            }
        } catch {
            errorText = error.localizedDescription
            return
        }

        errorText = nil
        isRunning = true
        // 起始阶段已经在上面确定好，从此刻起重新计算下一次判定的时间
        lastControlCheck = Date()
        acquireSleepAssertion()
    }

    /// 停止循环：恢复墙上供电并释放防睡眠断言
    func stop() {
        haltLoop()
        restoreAdapter()
    }

    /// 终止循环本身：复位阶段并释放防睡眠断言，不改动供电状态
    ///
    /// 供电交给调用方（手动切换）决定，因此这里不恢复适配器，避免与切换动作互相覆盖。
    private func haltLoop() {
        releaseSleepAssertion()
        isRunning = false
        phase = .idle
    }

    /// 退出应用前调用，避免把机器留在断电状态
    ///
    /// 直接调助手不触发安装：应用正在退出，此时弹授权框只会挡住退出流程。
    func restoreAdapterOnExit() {
        try? HelperClient.setAdapterEnabled(true)
    }

    /// 启动轮询定时器（用 common 模式，界面交互时不中断）
    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: uiRefreshInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// 读取一次电池状态并刷新界面数据，失败时设置错误提示并返回 false
    @discardableResult
    private func refreshStatus() -> Bool {
        guard let snapshot = BatteryMonitor.snapshot() else {
            errorText = L10n.batteryReadFailed
            return false
        }
        level = snapshot.level
        isPluggedIn = snapshot.isPluggedIn
        isCharging = snapshot.isCharging
        return true
    }

    /// 一次轮询：界面读数每次都刷新；状态机按较低频率判定，未开启时只刷新
    private func tick() {
        guard refreshStatus() else { return }
        guard isRunning else { return }

        // 电量变化缓慢，判定不必跟着界面刷新走；这里做频率限制以降低无谓的功耗与打扰
        guard Date().timeIntervalSince(lastControlCheck) >= controlMinInterval else { return }
        lastControlCheck = Date()

        switch phase {
        case .idle:
            return

        case .charging:
            if level >= highThreshold {
                // 到达上限 → 切断墙上供电，让电池开始真实放电
                do {
                    try applyAdapter(enabled: false, interactive: false)
                    phase = .discharging
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                }
            }

        case .discharging:
            if level <= lowThreshold {
                // 到达下限 → 恢复供电，重新开始充电
                do {
                    try applyAdapter(enabled: true, interactive: false)
                    phase = .charging
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    /// 界面显示的状态文案（供电情况由独立的 powerDescription 展示，这里只描述阶段）
    var statusText: String {
        switch phase {
        case .idle:
            return L10n.cycleStopped
        case .charging:
            return L10n.cycleCharging(to: highThreshold)
        case .discharging:
            return L10n.cycleDischarging(to: lowThreshold)
        }
    }

    /// 申请「禁止用户空闲睡眠」断言：放电途中若机器睡眠，循环会卡死
    private func acquireSleepAssertion() {
        guard sleepAssertionID == 0 else { return }
        var assertionID: IOPMAssertionID = 0
        let reason = L10n.sleepAssertionReason as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            sleepAssertionID = assertionID
        }
    }

    /// 释放防睡眠断言
    private func releaseSleepAssertion() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    /// 恢复墙上供电，失败只记录不抛出
    private func restoreAdapter() {
        do {
            try applyAdapter(enabled: true, interactive: false)
            // IOPS 的供电标志有数秒刷新延迟，先就地更新，避免停止后仍显示“使用电池供电”
            isPluggedIn = true
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
