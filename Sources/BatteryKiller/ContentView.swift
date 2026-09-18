import SwiftUI

/// 主界面：自动循环开关 + 手动电源切换 + 实时电量 + 循环区间滑杆 + 联系方式
struct ContentView: View {

    /// 充放电循环引擎
    @ObservedObject var engine: CycleEngine

    var body: some View {
        VStack(spacing: 18) {
            batteryReadout
            autoToggle
            powerSwitchButton
            thresholdPicker
            statusArea
            contactFooter
        }
        .padding(24)
        .frame(width: 320)
    }

    /// 电量读数区域：大号百分比 + 充电/供电指示
    private var batteryReadout: some View {
        VStack(spacing: 4) {
            Text("\(engine.level)%")
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(powerDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 供电状态描述
    private var powerDescription: String {
        if engine.isCharging { return "正在充电" }
        if engine.isPluggedIn { return "已插电，未充电" }
        return "使用电池供电"
    }

    /// 自动循环开关：打开即自动执行，按滑杆区间反复充放电
    private var autoToggle: some View {
        Toggle(isOn: Binding(
            get: { engine.isRunning },
            set: { isOn in isOn ? engine.start() : engine.stop() }
        )) {
            Text("自动循环")
        }
        .toggleStyle(.switch)
    }

    /// 手动切换供电来源
    private var powerSwitchButton: some View {
        Button(action: { engine.switchPowerSource() }) {
            Text("电池 / 直流电源 切换")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }

    /// 循环区间设置：拖动手柄选择电量区间，循环在这个区间内往返
    private var thresholdPicker: some View {
        VStack(spacing: 8) {
            HStack {
                Text("循环区间")
                Spacer()
                Text("\(engine.lowThreshold)% – \(engine.highThreshold)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            RangeSlider(
                lower: $engine.lowThreshold,
                upper: $engine.highThreshold,
                bounds: 1...100,
                lowerAnchors: [5, 10, 20, 30],
                upperAnchors: [80, 90, 100],
                isDisabled: engine.isRunning
            )
            HStack {
                Text("放电下限")
                Spacer()
                Text("停充上限")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    /// 状态与错误提示区域
    private var statusArea: some View {
        VStack(spacing: 6) {
            Text(engine.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let errorText = engine.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 页脚：作者联系方式
    private var contactFooter: some View {
        Link("@angiie_inside", destination: URL(string: "https://x.com/angiie_inside")!)
            .font(.caption)
    }
}
