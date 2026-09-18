import Foundation

/// batt 命令行工具的调用封装：负责开关墙上供电
enum BattController {

    /// batt 可执行文件路径（Homebrew 在 Apple Silicon 上的默认安装位置）
    static let executablePath = "/opt/homebrew/bin/batt"

    /// 可执行的控制动作
    enum Action {
        /// 解除 batt 的限充（batt 默认会把充电限制在 60%，不解除就永远充不到 100%）
        case allowFullCharge
        /// 恢复墙上供电（对应规则里的 start charge）
        case enableAdapter
        /// 切断墙上供电，用电池运行（对应规则里的 stop charge，同时产生放电）
        case disableAdapter

        /// 对应的 batt 命令行参数
        var arguments: [String] {
            switch self {
            case .allowFullCharge: return ["disable"]
            case .enableAdapter: return ["adapter", "enable"]
            case .disableAdapter: return ["adapter", "disable"]
            }
        }
    }

    /// 调用 batt 时可能出现的错误
    enum BattError: LocalizedError {
        /// 未安装 batt
        case notInstalled
        /// batt 守护进程不可用（未启动或没有权限）
        case daemonUnavailable
        /// 命令执行失败
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "未找到 batt，请先执行：brew install batt"
            case .daemonUnavailable:
                return "batt 守护进程未运行，请先在终端执行：sudo brew services start batt"
            case .commandFailed(let detail):
                return "batt 命令执行失败：\(detail)"
            }
        }
    }

    /// 执行一个控制动作，失败时抛出带原因的 BattError
    static func apply(_ action: Action) throws {
        _ = try run(arguments: action.arguments)
    }

    /// 同步执行 batt 命令并返回合并后的标准错误输出
    private static func run(arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw BattError.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BattError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // 守护进程未启动时 batt 同样以非零状态退出，必须先做关键字判定，
        // 否则会被下面的状态码分支吃掉，用户只能看到一长串原始报错
        if text.contains("daemon not running") || text.contains("connection refused") {
            throw BattError.daemonUnavailable
        }

        guard process.terminationStatus == 0 else {
            throw BattError.commandFailed(text)
        }
        return output
    }
}
