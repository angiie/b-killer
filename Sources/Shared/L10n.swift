import Foundation

/// 界面语言
enum AppLanguage {
    /// 中文
    case chinese
    /// 英文
    case english

    /// 当前生效的语言：系統首选语言以 zh 开头用中文，其余一律英文
    static let current: AppLanguage = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }()
}

/// 界面与错误提示文案
///
/// 错误文案会经由助手回传给主程序并显示在主界面，因此这份表放在 Shared 下，
/// 由主程序与特权助手两个目标共同编译，避免两侧各写一份。
enum L10n {

    /// 按当前语言在中英文之间二选一
    /// - Parameters:
    ///   - chinese: 中文文案
    ///   - english: 英文文案
    /// - Returns: 当前语言对应的文案
    private static func pick(_ chinese: String, _ english: String) -> String {
        AppLanguage.current == .chinese ? chinese : english
    }

    // MARK: - 主界面

    /// 自动循环开关标题
    static var autoCycle: String { pick("自动循环", "Auto Cycle") }

    /// 手动电源切换按钮标题
    static var switchPowerButton: String { pick("电池 / 直流电源 切换", "Switch Battery / DC Power") }

    /// 循环区间标题
    static var cycleRange: String { pick("循环区间", "Cycle Range") }

    /// 循环区间下限说明
    static var lowerBoundLabel: String { pick("放电下限", "Discharge Floor") }

    /// 循环区间上限说明
    static var upperBoundLabel: String { pick("停充上限", "Charge Ceiling") }

    /// 供电状态：正在充电
    static var powerCharging: String { pick("正在充电", "Charging") }

    /// 供电状态：已插电但未充电
    static var powerPluggedIdle: String { pick("已插电，未充电", "Plugged in, not charging") }

    /// 供电状态：使用电池
    static var powerOnBattery: String { pick("使用电池供电", "Running on battery") }

    // MARK: - 循环状态

    /// 循环未运行
    static var cycleStopped: String { pick("已停止", "Stopped") }

    /// 循环充电阶段
    /// - Parameter level: 循环区间上限
    static func cycleCharging(to level: Int) -> String {
        pick("充电中，等待升到 \(level)%", "Charging, waiting to reach \(level)%")
    }

    /// 循环放电阶段
    /// - Parameter level: 循环区间下限
    static func cycleDischarging(to level: Int) -> String {
        pick("已停止充电，放电中，等待降到 \(level)%", "Charging stopped, discharging to \(level)%")
    }

    // MARK: - 菜单栏

    /// 菜单项：显示窗口
    static var menuShowWindow: String { pick("显示窗口", "Show Window") }

    /// 菜单项：退出应用
    static var menuQuit: String { pick("退出 BatteryKiller", "Quit BatteryKiller") }

    /// 菜单项：切换到电池供电
    static var menuSwitchToBattery: String { pick("切换到电池供电", "Switch to Battery") }

    /// 菜单项：切换到直流电源
    static var menuSwitchToAdapter: String { pick("切换到直流电源", "Switch to DC Power") }

    // MARK: - 电池读取

    /// 读取电池状态失败
    static var batteryReadFailed: String { pick("无法读取电池状态", "Unable to read battery status") }

    /// 防睡眠断言的理由，会显示在「活动监视器 → 能耗」里
    static var sleepAssertionReason: String {
        pick(
            "维持充放电循环，防止空闲睡眠导致循环中断",
            "Keeping the charge cycle running, avoiding an idle sleep that would stall it"
        )
    }

    // MARK: - SMC 错误

    /// 内核未提供 AppleSMC 服务
    static var smcServiceUnavailable: String {
        pick("无法连接 AppleSMC 服务", "Cannot connect to the AppleSMC service")
    }

    /// 打开 AppleSMC 用户客户端失败
    /// - Parameter code: 内核返回码的十六进制文本
    static func smcOpenFailed(_ code: String) -> String {
        pick("打开 AppleSMC 失败：0x\(code)", "Failed to open AppleSMC: 0x\(code)")
    }

    /// SMC 调用失败
    /// - Parameters:
    ///   - key: SMC 键名
    ///   - code: 内核返回码的十六进制文本
    static func smcCallFailed(_ key: String, _ code: String) -> String {
        pick("SMC 调用失败（\(key)）：0x\(code)", "SMC call failed (\(key)): 0x\(code)")
    }

    /// SMC 键不存在
    /// - Parameter key: SMC 键名
    static func smcKeyNotFound(_ key: String) -> String {
        pick("SMC 键 \(key) 不存在", "SMC key \(key) not found")
    }

    /// SMC 键数据长度与预期不符
    /// - Parameters:
    ///   - key: SMC 键名
    ///   - expected: 期望字节数
    ///   - actual: 实际字节数
    static func smcUnexpectedSize(_ key: String, expected: Int, actual: Int) -> String {
        pick(
            "SMC 键 \(key) 数据长度异常：期望 \(expected) 字节，实际 \(actual) 字节",
            "SMC key \(key) returned \(actual) bytes, expected \(expected)"
        )
    }

    /// SMC 固件返回错误码
    /// - Parameters:
    ///   - key: SMC 键名
    ///   - code: 固件错误码
    static func smcDeviceError(_ key: String, _ code: UInt8) -> String {
        pick("SMC 键 \(key) 返回错误码 \(code)", "SMC key \(key) returned error code \(code)")
    }

    /// 写入 SMC 需要管理员权限
    /// - Parameter key: SMC 键名
    static func smcNotPrivileged(_ key: String) -> String {
        pick("写入 SMC 键 \(key) 需要管理员权限", "Writing SMC key \(key) requires administrator privileges")
    }

    // MARK: - 适配器错误

    /// 本机没有可用于控制墙上供电的 SMC 键
    static var adapterUnsupported: String {
        pick("本机不支持软件控制电源适配器", "This Mac does not support software control of the power adapter")
    }

    /// 写入后读回的值与预期不一致
    /// - Parameters:
    ///   - expected: 期望值的十六进制文本
    ///   - actual: 实际读回值的十六进制文本
    static func adapterVerifyFailed(expected: String, actual: String) -> String {
        pick(
            "适配器状态写入未生效：期望 \(expected)，实际 \(actual)",
            "Adapter state did not change: expected \(expected), got \(actual)"
        )
    }

    // MARK: - 特权助手

    /// 助手未安装或未运行
    static var helperNotInstalled: String {
        pick(
            "电源控制组件尚未安装，请重新开启一次并完成授权",
            "The power control helper is not installed. Toggle auto cycle once and grant authorization"
        )
    }

    /// 应用包内缺少助手文件
    static var helperBundleIncomplete: String {
        pick("应用包内缺少电源控制组件，请重新构建应用", "The app bundle is missing the helper, rebuild the app")
    }

    /// 用户取消授权
    static var helperAuthorizationCancelled: String {
        pick("已取消授权，电源控制不可用", "Authorization cancelled, power control unavailable")
    }

    /// 助手安装失败
    /// - Parameter detail: 安装脚本的输出
    static func helperInstallFailed(_ detail: String) -> String {
        pick("安装电源控制组件失败：\(detail)", "Failed to install the helper: \(detail)")
    }

    /// 助手启动超时
    static var helperStartTimeout: String {
        pick("电源控制组件启动超时，请稍后重试", "The helper did not start in time, try again later")
    }

    /// 助手返回业务错误
    /// - Parameter detail: 助手回复的错误详情
    static func helperOperationFailed(_ detail: String) -> String {
        pick("电源控制失败：\(detail)", "Power control failed: \(detail)")
    }

    /// 通讯层错误
    /// - Parameter detail: 具体原因
    static func helperCommunication(_ detail: String) -> String {
        pick("无法与电源控制组件通讯：\(detail)", "Cannot talk to the helper: \(detail)")
    }

    // MARK: - 通讯细节文本

    /// 创建 socket 失败
    static var socketCreateFailed: String { pick("无法创建 socket", "Failed to create socket") }

    /// socket 路径超出 sockaddr_un 容量
    static var socketPathTooLong: String { pick("socket 路径过长", "Socket path is too long") }

    /// 指令发送失败
    static var commandSendFailed: String { pick("指令发送失败", "Failed to send command") }

    /// 助手没有响应
    static var helperNoResponse: String { pick("助手没有响应", "The helper did not respond") }

    /// 助手回复无法识别
    /// - Parameter reply: 助手的原始回复
    static func unexpectedReply(_ reply: String) -> String {
        pick("无法识别的回复：\(reply)", "Unrecognized reply: \(reply)")
    }

    /// 助手不支持的指令
    static var unsupportedCommand: String { pick("不支持的指令", "Unsupported command") }
}
