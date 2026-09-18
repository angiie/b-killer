import Combine
import Foundation

/// 界面语言设置
///
/// 单一数据源：读取并持久化用户的手动选择，把它写入 L10n 使用的 `AppLanguage.current`，
/// 并通过 `@Published` 通知 SwiftUI 视图与状态栏菜单刷新文案。
/// 未手动选择过时跟随系统语言。
///
/// 助手进程不读这里：主程序每次发指令都会带上当前语言，助手据此决定错误文案的语言，
/// 因此不存在「主程序切了语言但助手还是旧的」的窗口期。
final class LanguageStore: ObservableObject {

    /// 全局单例
    static let shared = LanguageStore()

    /// 当前语言；变化后界面与菜单栏各自刷新
    @Published private(set) var language: AppLanguage

    /// 持久化手动选择所用的键
    private static let defaultsKey = "AppLanguage"

    /// 读取持久化的选择；没有记录时跟随系统语言
    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        language = saved.flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        AppLanguage.current = language
    }

    /// 在中文与英文之间切换
    func toggle() {
        apply(language == .chinese ? .english : .chinese)
    }

    /// 应用一种语言：更新文案表、持久化并通知观察者
    /// - Parameter newValue: 目标语言；与当前相同时直接返回
    private func apply(_ newValue: AppLanguage) {
        guard newValue != language else { return }
        language = newValue
        AppLanguage.current = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
    }
}
