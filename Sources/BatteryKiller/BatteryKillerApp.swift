import SwiftUI

/// 全局单例容器：让应用委托与 SwiftUI 视图共享同一个循环引擎与语言设置
enum AppState {
    /// 语言设置：初始化时读取持久化的语言选择并应用到文案表
    static let language = LanguageStore.shared

    /// 充放电循环引擎
    static let engine = CycleEngine()
}

/// 应用委托：管理状态栏常驻、关窗隐藏与退出时的供电恢复
///
/// 关闭窗口只是把窗口隐藏并收起 Dock 图标，应用继续在状态栏运行循环；
/// 只有从状态栏右键菜单选择退出才会真正结束进程。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    /// 状态栏图标控制器
    private var menuBar: MenuBarController?
    /// 主窗口的弱引用（窗口本身由 SwiftUI 持有）
    private weak var mainWindow: NSWindow?

    /// 启动时挂上状态栏图标
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先让语言设置生效，再建界面与菜单，避免首帧用错语言
        _ = AppState.language

        menuBar = MenuBarController(
            engine: AppState.engine,
            onShowWindow: { [weak self] in self?.showMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// 关掉窗口不结束应用，循环要继续跑
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 拦截关窗：只隐藏窗口并收起 Dock 图标，不销毁窗口
    ///
    /// 之所以不真正关闭窗口，是因为 SwiftUI 的 WindowGroup 一旦销毁窗口就难以原样重建，
    /// 隐藏后可以直接 makeKeyAndOrderFront 唤回，界面状态也得以保留。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    /// 由 SwiftUI 侧在窗口就绪时调用，把主窗口接管过来
    /// - Parameter window: SwiftUI 创建的主窗口
    func attach(window: NSWindow) {
        mainWindow = window
        window.delegate = self
    }

    /// 唤出主窗口：恢复 Dock 图标并置于前台
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// 退出前恢复适配器供电
    func applicationWillTerminate(_ notification: Notification) {
        AppState.engine.restoreAdapterOnExit()
    }
}

/// 把 SwiftUI 场景底层的 NSWindow 暴露出来，便于设置窗口代理
private struct WindowAccessor: NSViewRepresentable {

    /// 窗口就绪后的回调
    let onWindowReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 视图刚创建时还没挂到窗口上，延到下一轮运行循环再取
        DispatchQueue.main.async {
            if let window = view.window { onWindowReady(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 应用入口：单窗口 SwiftUI App
@main
struct BatteryKillerApp: App {

    /// 应用级委托
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("BatteryKiller") {
            ContentView(engine: AppState.engine)
                .background(WindowAccessor { window in
                    appDelegate.attach(window: window)
                })
        }
        .windowResizability(.contentSize)
    }
}
