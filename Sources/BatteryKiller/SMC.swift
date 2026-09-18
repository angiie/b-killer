import Foundation
import IOKit

/// AppleSMC 访问失败的原因
enum SMCError: LocalizedError {
    /// 内核未提供 AppleSMC 服务（非 Apple 硬件，或系统异常）
    case serviceUnavailable
    /// 打开 user client 失败
    case openFailed(kern_return_t)
    /// Mach 调用失败
    case callFailed(String, kern_return_t)
    /// 键不存在
    case keyNotFound(String)
    /// 数据长度不符合预期
    case unexpectedSize(String, expected: Int, actual: Int)
    /// SMC 固件返回错误码
    case deviceError(String, UInt8)
    /// 内核拒绝写入（当前进程没有 root 权限）
    case notPrivileged(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "无法连接 AppleSMC 服务"
        case .openFailed(let code):
            return "打开 AppleSMC 失败：0x\(hex(code))"
        case .callFailed(let key, let code):
            return "SMC 调用失败（\(key)）：0x\(hex(code))"
        case .keyNotFound(let key):
            return "SMC 键 \(key) 不存在"
        case .unexpectedSize(let key, let expected, let actual):
            return "SMC 键 \(key) 数据长度异常：期望 \(expected) 字节，实际 \(actual) 字节"
        case .deviceError(let key, let code):
            return "SMC 键 \(key) 返回错误码 \(code)"
        case .notPrivileged(let key):
            return "写入 SMC 键 \(key) 需要管理员权限"
        }
    }

    /// 把内核返回码格式化成可读的十六进制
    private func hex(_ code: kern_return_t) -> String {
        String(UInt32(bitPattern: code), radix: 16)
    }
}

/// 内核在权限不足时返回的错误码（kIOReturnNotPrivileged）
///
/// 该宏无法被 Swift 直接引入，只能按数值写死；实测非 root 写 SMC 时必然命中它。
private let kIOReturnNotPrivileged: kern_return_t = kern_return_t(bitPattern: 0xE00002C1)

/// 把四字符键名打包成 SMC 使用的 32 位整数
/// - Parameter name: 键名，不足四位时以空格补齐
func smcFourCharCode(_ name: String) -> UInt32 {
    let prefix = Array(name.utf8.prefix(4))
    let padding = Array(repeating: UInt8(ascii: " "), count: max(0, 4 - prefix.count))
    var code: UInt32 = 0
    for byte in prefix + padding {
        code = (code << 8) | UInt32(byte)
    }
    return code
}

/// 把 SMC 键名还原成可读字符串，用于错误提示
/// - Parameter key: 四字符键的整数值
func smcKeyName(_ key: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: key >> UInt32($0)) }
    return String(bytes: bytes, encoding: .ascii) ?? String(key)
}

/// AppleSMC 用户客户端连接
///
/// 实测结论（M1 / 固件 18000.161.10 / macOS 26.6.2）：
/// 非 root 进程可以打开连接、读取任意键的元信息与数据，但**所有写入**都会被内核
/// 以 kIOReturnNotPrivileged 拒绝（连物理只读的传感器键也一样）。
/// 因此读取可以放在 GUI 进程内，写入必须交给以 root 运行的助手进程。
final class SMCConnection {

    /// 内核连接端口，0 表示尚未打开
    private var connect: io_connect_t = 0

    /// 打开与 AppleSMC 的连接；已打开时直接返回
    func open() throws {
        guard connect == 0 else { return }
        // 结构体布局必须与内核一致，偏移错一位就会解析出垃圾数据
        precondition(MemoryLayout<SMCParamStruct>.size == 80, "SMCParamStruct 布局与内核不一致")

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceUnavailable }
        defer { IOObjectRelease(service) }

        var handle: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 1, &handle)
        guard result == kIOReturnSuccess, handle != 0 else {
            throw SMCError.openFailed(result)
        }
        // 告知内核扩展本进程开始使用；失败不影响后续读写，故忽略返回值
        IOConnectCallScalarMethod(handle, UInt32(kSMCUserClientOpen), nil, 0, nil, nil)
        connect = handle
    }

    /// 关闭连接；重复调用无副作用
    func close() {
        guard connect != 0 else { return }
        IOConnectCallScalarMethod(connect, UInt32(kSMCUserClientClose), nil, 0, nil, nil)
        IOServiceClose(connect)
        connect = 0
    }

    /// 读取一个键的元信息
    /// - Parameter key: 四字符键的整数值
    /// - Returns: 数据长度、类型码与属性位
    func keyInfo(_ key: UInt32) throws -> (dataSize: UInt32, dataType: UInt32, attributes: UInt8) {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = UInt8(kSMCGetKeyInfo)
        let output = try call(&input, key: key)
        return (output.keyInfo.dataSize, output.keyInfo.dataType, output.keyInfo.dataAttributes)
    }

    /// 读取一个键的数据
    /// - Parameters:
    ///   - key: 四字符键的整数值
    ///   - size: 期望读取的字节数，须与 keyInfo 返回的 dataSize 一致
    /// - Returns: 数据载荷
    func read(_ key: UInt32, size: Int) throws -> [UInt8] {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(size)
        input.data8 = UInt8(kSMCReadKey)
        let output = try call(&input, key: key)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
    }

    /// 写入一个键的数据
    /// - Parameters:
    ///   - key: 四字符键的整数值
    ///   - bytes: 待写入的数据，最多 32 字节
    /// - Note: 需要 root 权限，否则抛出 SMCError.notPrivileged
    func write(_ key: UInt32, bytes: [UInt8]) throws {
        precondition(bytes.count <= 32, "SMC 单次写入不能超过 32 字节")
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = UInt8(kSMCWriteKey)
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            buffer.copyBytes(from: bytes)
        }
        _ = try call(&input, key: key)
    }

    /// 发起一次 SMC 调用并把内核与固件的错误统一转成 SMCError
    /// - Parameters:
    ///   - input: 输入消息，内容由调用方按命令码填好
    ///   - key: 键名，仅用于错误提示
    /// - Returns: 内核回填的输出消息
    private func call(_ input: inout SMCParamStruct, key: UInt32) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let result = IOConnectCallStructMethod(
            connect,
            UInt32(kSMCHandleYPCEvent),
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        if result == kIOReturnNotPrivileged {
            throw SMCError.notPrivileged(smcKeyName(key))
        }
        guard result == kIOReturnSuccess else {
            throw SMCError.callFailed(smcKeyName(key), result)
        }
        if output.result == UInt8(kSMCKeyNotFound) {
            throw SMCError.keyNotFound(smcKeyName(key))
        }
        guard output.result == UInt8(kSMCSuccess) else {
            throw SMCError.deviceError(smcKeyName(key), output.result)
        }
        return output
    }

    deinit {
        close()
    }
}
