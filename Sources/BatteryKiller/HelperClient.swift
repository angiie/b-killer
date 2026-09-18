import Foundation

/// 与特权助手交互或安装助手时的失败原因
enum HelperError: LocalizedError {
    /// 助手尚未安装，或已安装但没有运行
    case notInstalled
    /// 应用包内缺少助手文件，通常是构建方式不对
    case bundleIncomplete
    /// 用户在授权对话框中取消
    case authorizationCancelled
    /// 安装脚本执行失败
    case installFailed(String)
    /// 安装完成后助手仍未就绪
    case startTimeout
    /// 助手返回了业务错误
    case operationFailed(String)
    /// 通讯层错误
    case communication(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return L10n.helperNotInstalled
        case .bundleIncomplete:
            return L10n.helperBundleIncomplete
        case .authorizationCancelled:
            return L10n.helperAuthorizationCancelled
        case .installFailed(let detail):
            return L10n.helperInstallFailed(detail)
        case .startTimeout:
            return L10n.helperStartTimeout
        case .operationFailed(let detail):
            return L10n.helperOperationFailed(detail)
        case .communication(let detail):
            return L10n.helperCommunication(detail)
        }
    }
}

/// 特权电源助手（bkhelper）的客户端与安装器
///
/// 主程序以登录用户身份运行，无权写 AppleSMC，所有需要 root 的电源操作都通过
/// 与助手之间的一条 Unix socket 连接完成。助手协议只有固定几条指令，
/// 不接受任何参数化输入，因此这条连接能被滥用的范围仅限于“切换一次电源来源”。
enum HelperClient {

    /// 协议版本，必须与助手内的常量一致；不一致说明应用包内的助手比已安装的新
    static let protocolVersion = 1

    /// 助手标识，同时决定 socket 路径与系统内的安装路径
    static let label = "com.bkiller.batterykiller.helper"

    /// 特权二进制的安装位置（/Library/PrivilegedHelperTools 是系统约定的助手目录）
    static let installedPath = "/Library/PrivilegedHelperTools/\(label)"

    /// launchd 描述文件的安装位置
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// 助手监听的 socket 路径
    static let socketPath = "/var/run/\(label).sock"

    /// 通讯超时，避免助手异常时拖住界面
    private static let socketTimeout = timeval(tv_sec: 5, tv_usec: 0)

    /// 检查助手是否可用：能连上且协议版本一致
    /// - Returns: 可用返回 true
    static func isReady() -> Bool {
        (try? send("VERSION")) == String(protocolVersion)
    }

    /// 设置适配器启用状态
    /// - Parameter enabled: true 接通墙上供电，false 切断改用电池
    static func setAdapterEnabled(_ enabled: Bool) throws {
        _ = try send(enabled ? "ON" : "OFF")
    }

    /// 读取适配器当前是否启用
    /// - Returns: 启用返回 true
    static func isAdapterEnabled() throws -> Bool {
        try send("STATUS") == "ON"
    }

    /// 安装或升级助手
    ///
    /// 需要 root：把应用包内的助手二进制与 launchd 描述文件装入系统目录并常驻拉起。
    /// 授权对话框由 osascript 弹出，只有这一次，之后不再需要授权。
    static func install() throws {
        let bundlePath = Bundle.main.bundleURL.path
        let helperSource = "\(bundlePath)/Contents/MacOS/bkhelper"
        let plistSource = "\(bundlePath)/Contents/Library/LaunchDaemons/\(label).plist"

        let manager = FileManager.default
        guard manager.fileExists(atPath: helperSource), manager.fileExists(atPath: plistSource) else {
            throw HelperError.bundleIncomplete
        }

        // 先 bootout 再 bootstrap，保证升级时能替换掉旧版本
        let script = """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        /usr/bin/install -m 755 -o root -g wheel \(shellQuote(helperSource)) \(shellQuote(installedPath))
        /usr/bin/install -m 644 -o root -g wheel \(shellQuote(plistSource)) \(shellQuote(plistPath))
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system \(shellQuote(plistPath))
        """

        try runAsAdministrator(script)
        try waitUntilReady()
    }

    /// 发送一条指令并返回去掉成功前缀后的回复内容
    /// - Parameter command: 指令文本，不含换行
    /// - Returns: 助手的回复正文
    private static func send(_ command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError.communication(L10n.socketCreateFailed) }
        defer { close(fd) }

        var timeout = socketTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var address = UnixSocket.address(for: socketPath) else {
            throw HelperError.communication(L10n.socketPathTooLong)
        }
        let connectResult = UnixSocket.withSockaddr(&address) { pointer, length in
            connect(fd, pointer, length)
        }
        guard connectResult == 0 else {
            let code = errno
            // socket 不存在或没有进程监听，都说明助手没装好或没跑起来
            if code == ENOENT || code == ECONNREFUSED { throw HelperError.notInstalled }
            throw HelperError.communication(String(cString: strerror(code)))
        }

        let request = Array((command + "\n").utf8)
        guard request.withUnsafeBufferPointer({ write(fd, $0.baseAddress, $0.count) }) == request.count else {
            throw HelperError.communication(L10n.commandSendFailed)
        }

        var buffer = [UInt8](repeating: 0, count: 128)
        var received = 0
        while received < buffer.count {
            let count = read(fd, &buffer[received], buffer.count - received)
            guard count > 0 else { break }
            received += count
            if buffer[0..<received].contains(UInt8(ascii: "\n")) { break }
        }

        guard received > 0, let text = String(bytes: buffer[0..<received], encoding: .utf8) else {
            throw HelperError.communication(L10n.helperNoResponse)
        }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.hasPrefix("ERR") {
            throw HelperError.operationFailed(reply.dropFirst(3).trimmingCharacters(in: .whitespaces))
        }
        guard reply.hasPrefix("OK") else {
            throw HelperError.communication(L10n.unexpectedReply(reply))
        }
        return reply.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    /// 以系统管理员身份执行一段 shell 脚本
    /// - Parameter script: 脚本内容
    private static func runAsAdministrator(_ script: String) throws {
        // 脚本整体作为 AppleScript 字符串字面量，需要转义反斜杠与双引号
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }
        let detail = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 用户在授权对话框点取消时 osascript 会返回这句话
        if detail.contains("User canceled") { throw HelperError.authorizationCancelled }
        throw HelperError.installFailed(detail)
    }

    /// 等待 launchd 把助手拉起并建立 socket
    private static func waitUntilReady() throws {
        for _ in 0..<40 {
            if isReady() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw HelperError.startTimeout
    }

    /// 按 shell 单引号规则转义一个值
    /// - Parameter value: 待转义的文本
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
