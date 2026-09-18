import Foundation

/// 适配器控制失败的原因
enum AdapterError: LocalizedError {
    /// 本机没有可用于控制墙上供电的 SMC 键
    case unsupportedHardware
    /// 写入后读回的值与预期不一致，说明固件没有接受这次写入
    case verifyFailed(expected: [UInt8], actual: [UInt8])

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return L10n.adapterUnsupported
        case .verifyFailed(let expected, let actual):
            let expectedText = expected.map { String(format: "%02X", $0) }.joined()
            let actualText = actual.map { String(format: "%02X", $0) }.joined()
            return L10n.adapterVerifyFailed(expected: expectedText, actual: actualText)
        }
    }
}

/// 墙上供电（电源适配器）的开关控制
///
/// 键与取值来自对本机 SMC 的直接实测（M1 / 固件 18000.161.10 / macOS 26.6.2）：
/// 用 batt 切换适配器前后对全部候选键做快照 diff，**只有 CHIE 发生变化**，
/// 其余键（CHTE / CH0D / AC-W / CHTC）纹丝不动，据此确定语义：
///
///   CHIE = 0x00 → 适配器启用，机器走墙上供电
///   CHIE = 0x08 → 适配器切断，机器走电池供电（充电器仍物理接着）
///
/// 本机键的可用性：
///   - CH0I / CH0B / CH0C / bfF0 / bfE0 / ACLC 不存在
///   - CH0J 存在但元信息与数据读取均被内核 entitlement 拒绝，无法使用
///   - bfD0 存在但属性为 0x84（只读），且缺少配对的 bfF0 / bfE0，非固件托管模式
///
/// 注意 CHIE 只表示“电源通路的意愿”，不表示充电器是否物理接入；
/// 后者应读 SMC 的 AC-W 或系统的 IOKit 电源接口。
final class AdapterControl {

    /// 适配器开关对应的 SMC 键
    static let key = smcFourCharCode("CHIE")

    /// 启用值：适配器接通
    static let enabledValue: [UInt8] = [0x00]

    /// 切断值：适配器断开，改用电池
    static let disabledValue: [UInt8] = [0x08]

    /// 底层 SMC 连接
    private let connection = SMCConnection()

    /// 打开底层连接
    func open() throws {
        try connection.open()
    }

    /// 关闭底层连接
    func close() {
        connection.close()
    }

    /// 探测本机是否支持软件控制适配器
    ///
    /// 读取键元信息不需要 root，因此可以在安装特权助手之前先判断硬件是否支持，
    /// 避免在不支持的机器上弹出无意义的授权对话框。
    /// - Returns: 支持返回 true
    static func isSupported() -> Bool {
        let probe = SMCConnection()
        do {
            try probe.open()
            defer { probe.close() }
            // 长度必须精确为 1 字节：新固件会留下长度为 0 的占位键，不能当作可用
            return try probe.keyInfo(key).dataSize == 1
        } catch {
            return false
        }
    }

    /// 读取适配器当前是否启用
    /// - Returns: 启用（走墙上供电）返回 true；仅凭此值无法判断充电器是否物理接入
    func isEnabled() throws -> Bool {
        let value = try connection.read(Self.key, size: Self.enabledValue.count)
        return value == Self.enabledValue
    }

    /// 设置适配器启用状态
    /// - Parameter enabled: true 接通墙上供电，false 切断改用电池
    /// - Note: 需要 root 权限；写完立即读回比对，因为 SMC 固件存在谎报成功的情况
    func setEnabled(_ enabled: Bool) throws {
        let expected = enabled ? Self.enabledValue : Self.disabledValue
        try connection.write(Self.key, bytes: expected)

        let actual = try connection.read(Self.key, size: expected.count)
        guard actual == expected else {
            throw AdapterError.verifyFailed(expected: expected, actual: actual)
        }
    }
}
