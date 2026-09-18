import Foundation

/// 特权电源助手（bkhelper）
///
/// 为什么需要独立进程：写 AppleSMC 会被内核以 kIOReturnNotPrivileged 拒绝，
/// 只有 root 进程能写；而 GUI 进程始终以登录用户身份运行。
///
/// 设计取舍：
///   - 由 launchd 以 root 常驻拉起，装机一次即可长期使用，不需要反复授权；
///   - 对外协议刻意做到最小：一行指令、一行回复，不接受任何参数化输入，
///     暴露面仅“查状态 / 接通 / 切断”三件事；
///   - 每次请求新建 SMC 连接，避免开机时 SMC 尚未就绪导致长连接失效。

/// 协议版本。主程序据此判断应用包内的助手是否比已安装的新，需要重装
let helperProtocolVersion = 1

/// 默认 socket 路径
let defaultSocketPath = "/var/run/com.bkiller.batterykiller.helper.sock"

/// 从命令行参数取 socket 路径，缺省用默认值
/// - Returns: socket 文件路径
func socketPathFromArguments() -> String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count else {
        return defaultSocketPath
    }
    return arguments[index + 1]
}

/// 输出一行日志到标准错误（由 launchd 收集到 plist 指定的日志文件）
/// - Parameter message: 日志内容
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// 处理一条请求
/// - Parameter command: 请求文本，不含换行
/// - Returns: 以 "OK" 开头表示成功、以 "ERR" 开头表示失败
func handle(_ command: String) -> String {
    switch command {
    case "VERSION":
        return "OK \(helperProtocolVersion)"
    case "STATUS", "ON", "OFF":
        let adapter = AdapterControl()
        do {
            try adapter.open()
            defer { adapter.close() }
            if command == "STATUS" {
                return try adapter.isEnabled() ? "OK ON" : "OK OFF"
            }
            try adapter.setEnabled(command == "ON")
            return "OK"
        } catch {
            return "ERR \(error.localizedDescription)"
        }
    default:
        return "ERR \(L10n.unsupportedCommand)"
    }
}

// MARK: - 启动

let socketPath = socketPathFromArguments()

guard var address = UnixSocket.address(for: socketPath) else {
    log("socket 路径过长：\(socketPath)")
    exit(1)
}

let server = socket(AF_UNIX, SOCK_STREAM, 0)
guard server >= 0 else {
    log("创建 socket 失败：\(String(cString: strerror(errno)))")
    exit(1)
}

// 上一次异常退出可能留下 socket 文件，先清掉再绑定
unlink(socketPath)

let bindResult = UnixSocket.withSockaddr(&address) { pointer, length in
    bind(server, pointer, length)
}
guard bindResult == 0 else {
    log("绑定 \(socketPath) 失败：\(String(cString: strerror(errno)))")
    exit(1)
}

// 允许本地用户连接。可被滥用的范围仅有三条固定指令，最坏情况是被切一次电源来源，
// 与 batt 现有守护进程的 socket 权限相当，且没有 batt 那样庞大的可调用接口。
chmod(socketPath, 0o666)

guard listen(server, 16) == 0 else {
    log("监听失败：\(String(cString: strerror(errno)))")
    exit(1)
}

log("bkhelper 已就绪，监听 \(socketPath)")

/// 一次连接处理一条指令
while true {
    let client = accept(server, nil, nil)
    guard client >= 0 else { continue }

    // 客户端连上却不发指令时不能拖住整个循环
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var buffer = [UInt8](repeating: 0, count: 128)
    var received = 0
    while received < buffer.count {
        let count = read(client, &buffer[received], buffer.count - received)
        guard count > 0 else { break }
        received += count
        if buffer[0..<received].contains(UInt8(ascii: "\n")) { break }
    }

    let request = String(bytes: buffer[0..<received], encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let reply = Array((handle(request) + "\n").utf8)
    reply.withUnsafeBufferPointer { pointer in
        _ = write(client, pointer.baseAddress, pointer.count)
    }
    if !request.isEmpty {
        log("\(request) -> \(String(bytes: reply, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }
    close(client)
}
