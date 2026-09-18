import AppKit
import Combine

/// 状态栏图标控制器：常驻菜单栏显示当前供电方式，并提供循环/切换快捷开关
///
/// 菜单由系统托管（直接把 NSMenu 挂给 NSStatusItem），左右键点击都会弹出，
/// 这是最可靠的方式；退出应用只能从这里触发。
final class MenuBarController {

    /// 状态栏项
    private let statusItem: NSStatusItem
    /// 菜单，含循环开关、电源切换、唤出窗口与退出
    private let menu = NSMenu()
    /// 循环引擎，菜单项直接操作它
    private let engine: CycleEngine
    /// 「自动循环」菜单项，勾选状态即循环是否在跑
    private let autoCycleItem = NSMenuItem()
    /// 「手动切换」菜单项，标题随当前供电状态变化
    private let switchPowerItem = NSMenuItem()
    /// 供电状态订阅，用于切换图标与切换项标题
    private var powerStateSubscription: AnyCancellable?
    /// 循环运行状态订阅，用于同步「自动循环」勾选
    private var runStateSubscription: AnyCancellable?

    /// 唤出主窗口的回调
    private let onShowWindow: () -> Void
    /// 退出应用的回调
    private let onQuit: () -> Void

    /// 状态栏图标的逻辑尺寸（菜单栏高度 24pt，图标取 18pt）
    private let iconSize = NSSize(width: 18, height: 18)

    /// 初始化并挂载状态栏项
    /// - Parameters:
    ///   - engine: 供电状态与控制动作的来源
    ///   - onShowWindow: 选择「显示窗口」时唤出主窗口
    ///   - onQuit: 选择退出时结束应用
    init(engine: CycleEngine, onShowWindow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.engine = engine
        self.onShowWindow = onShowWindow
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        configureMenu()
        // 先按当前状态填一次，等订阅回调到达前菜单与图标就是对的
        updateIcon(isPluggedIn: engine.isPluggedIn)
        updateSwitchItemTitle(isPluggedIn: engine.isPluggedIn)
        autoCycleItem.state = engine.isRunning ? .on : .off
        subscribePowerState(engine: engine)
        subscribeRunState(engine: engine)
    }

    /// 配置状态栏按钮；菜单挂在 statusItem 上，因此按钮自身不需要 action
    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.toolTip = "BatteryKiller"
    }

    /// 配置菜单：显示窗口 + 自动循环开关 + 手动切换 + 退出
    private func configureMenu() {
        let showItem = NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        autoCycleItem.title = "自动循环"
        autoCycleItem.action = #selector(toggleAutoCycle)
        autoCycleItem.target = self
        menu.addItem(autoCycleItem)

        switchPowerItem.action = #selector(switchPowerSource)
        switchPowerItem.target = self
        menu.addItem(switchPowerItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 BatteryKiller", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// 订阅供电状态：插电时用电源图标，否则用电池图标，同时更新切换项标题
    private func subscribePowerState(engine: CycleEngine) {
        powerStateSubscription = engine.$isPluggedIn
            .receive(on: RunLoop.main)
            .sink { [weak self] isPluggedIn in
                self?.updateIcon(isPluggedIn: isPluggedIn)
                self?.updateSwitchItemTitle(isPluggedIn: isPluggedIn)
            }
    }

    /// 订阅循环运行状态，让「自动循环」菜单项的勾选跟上开关变化
    private func subscribeRunState(engine: CycleEngine) {
        runStateSubscription = engine.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] isRunning in
                self?.autoCycleItem.state = isRunning ? .on : .off
            }
    }

    /// 按供电方式切换状态栏图标
    private func updateIcon(isPluggedIn: Bool) {
        guard let button = statusItem.button else { return }
        let name = isPluggedIn ? "status-adapter" : "status-battery"
        guard let image = NSImage(named: name) else { return }
        image.size = iconSize
        // 保留 SVG 原有的红/黄配色，不使用系统单色模板渲染
        image.isTemplate = false
        button.image = image
    }

    /// 「手动切换」项标题提示点击后会切到哪一边
    private func updateSwitchItemTitle(isPluggedIn: Bool) {
        switchPowerItem.title = isPluggedIn ? "切换到电池供电" : "切换到直流电源"
    }

    /// 菜单项：唤出主窗口
    @objc private func showWindow() {
        onShowWindow()
    }

    /// 菜单项：开关自动循环（与手动切换互斥，开启后供电由循环接管）
    @objc private func toggleAutoCycle() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.start()
        }
    }

    /// 菜单项：手动切换供电来源（与自动循环互斥，切换即终止循环）
    @objc private func switchPowerSource() {
        engine.switchPowerSource()
    }

    /// 菜单项：退出应用
    @objc private func quit() {
        onQuit()
    }
}
