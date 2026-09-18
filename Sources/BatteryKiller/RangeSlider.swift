import SwiftUI

/// 双滑块区间选择器：拖动手柄或直接点击轨道来选取区间 [lower, upper]
///
/// 轨道下方标出锚点刻度；拖动或点击落在锚点附近时会吸附到该锚点，方便精确选取预设值。
/// 点击轨道时由「离点击位置更近的那个手柄」响应，所以不必先抓住手柄就能快速设置。
struct RangeSlider: View {

    /// 区间下限（左手柄）
    @Binding var lower: Int
    /// 区间上限（右手柄）
    @Binding var upper: Int
    /// 允许选取的整体数值范围
    let bounds: ClosedRange<Int>
    /// 下限的吸附锚点
    var lowerAnchors: [Int] = []
    /// 上限的吸附锚点
    var upperAnchors: [Int] = []
    /// 是否禁用交互（循环运行中禁止改区间）
    var isDisabled: Bool = false

    /// 手柄直径
    private let handleSize: CGFloat = 16
    /// 轨道高度
    private let trackHeight: CGFloat = 4
    /// 锚点刻度线高度
    private let tickHeight: CGFloat = 5
    /// 锚点文字标签的字号
    private let labelFontSize: CGFloat = 9
    /// 两个手柄之间保留的最小间隔，避免区间退化成一个点导致频繁反复切换
    private let minGap: Int = 2
    /// 吸附容差（数值单位）：与锚点的距离在此范围内就吸附过去
    private let snapTolerance: Int = 2
    /// 拖动坐标系的名称，用于把手势位置换算到整条轨道的坐标
    private static let spaceName = "RangeSliderSpace"

    /// 锚点刻度相对顶部的偏移，放在手柄下方以免被手柄遮住
    private var tickOffsetY: CGFloat { handleSize + 1 }
    /// 文字标签高度
    private var labelHeight: CGFloat { labelFontSize + 3 }
    /// 文字标签相对顶部的偏移，排在刻度线下方
    private var labelOffsetY: CGFloat { tickOffsetY + tickHeight + 2 }
    /// 控件总高度（手柄 + 刻度线 + 文字标签）
    private var totalHeight: CGFloat { labelOffsetY + labelHeight }
    /// 需要绘制的全部刻度（上下限锚点合并去重后排序）
    private var allAnchors: [Int] { Array(Set(lowerAnchors + upperAnchors)).sorted() }

    var body: some View {
        GeometryReader { geo in
            // 手柄会占到两端各半个直径，轨道可用宽度要扣掉这部分，手柄才不会溢出控件
            let trackWidth = max(1, geo.size.width - handleSize)
            let lowerX = handleSize / 2 + ratio(for: lower) * trackWidth
            let upperX = handleSize / 2 + ratio(for: upper) * trackWidth
            let trackY = (handleSize - trackHeight) / 2

            ZStack(alignment: .topLeading) {
                // 铺满控件的透明点击区：点轨道任意位置都能设置更近的那个手柄
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: totalHeight)
                    .allowsHitTesting(!isDisabled)
                    .gesture(clickGesture(trackWidth: trackWidth))

                // 底色轨道
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: trackWidth, height: trackHeight)
                    .offset(x: handleSize / 2, y: trackY)

                // 已选中的区间
                Capsule()
                    .fill(isDisabled ? Color.secondary : Color.accentColor)
                    .frame(width: max(0, upperX - lowerX), height: trackHeight)
                    .offset(x: lowerX, y: trackY)

                anchorTicks(trackWidth: trackWidth)
                anchorLabels(trackWidth: trackWidth)

                handle
                    .offset(x: lowerX - handleSize / 2)
                    .allowsHitTesting(!isDisabled)
                    .gesture(dragGesture(isLower: true, trackWidth: trackWidth))

                handle
                    .offset(x: upperX - handleSize / 2)
                    .allowsHitTesting(!isDisabled)
                    .gesture(dragGesture(isLower: false, trackWidth: trackWidth))
            }
            .coordinateSpace(name: Self.spaceName)
        }
        .frame(height: totalHeight)
    }

    /// 单个手柄的外观
    private var handle: some View {
        Circle()
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                Circle().stroke(isDisabled ? Color.secondary : Color.accentColor, lineWidth: 2)
            )
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
    }

    /// 锚点刻度线（不参与命中测试，避免挡住轨道的点击）
    private func anchorTicks(trackWidth: CGFloat) -> some View {
        ForEach(allAnchors, id: \.self) { value in
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 1.5, height: tickHeight)
                .offset(x: handleSize / 2 + ratio(for: value) * trackWidth - 0.75, y: tickOffsetY)
                .allowsHitTesting(false)
        }
    }

    /// 锚点文字标签，居中排在对应刻度线正下方（不参与命中测试，避免挡住轨道的点击）
    private func anchorLabels(trackWidth: CGFloat) -> some View {
        ForEach(allAnchors, id: \.self) { value in
            Text("\(value)")
                .font(.system(size: labelFontSize))
                .foregroundStyle(.secondary)
                .fixedSize()
                .position(
                    x: handleSize / 2 + ratio(for: value) * trackWidth,
                    y: labelOffsetY + labelHeight / 2
                )
                .allowsHitTesting(false)
        }
    }

    /// 点击轨道：由更近的手柄响应，并吸附到该手柄对应的锚点
    private func clickGesture(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.spaceName))
            .onEnded { gesture in
                let x = gesture.location.x
                let lowerX = handleSize / 2 + ratio(for: lower) * trackWidth
                let upperX = handleSize / 2 + ratio(for: upper) * trackWidth
                let raw = value(at: x, trackWidth: trackWidth)

                if abs(x - lowerX) <= abs(x - upperX) {
                    lower = min(snapped(raw, anchors: lowerAnchors), upper - minGap)
                } else {
                    upper = max(snapped(raw, anchors: upperAnchors), lower + minGap)
                }
            }
    }

    /// 拖动单个手柄：换算成数值并吸附锚点，同时保证两个手柄不交叉
    private func dragGesture(isLower: Bool, trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.spaceName))
            .onChanged { gesture in
                let raw = value(at: gesture.location.x, trackWidth: trackWidth)
                let value = snapped(raw, anchors: isLower ? lowerAnchors : upperAnchors)
                if isLower {
                    lower = min(value, upper - minGap)
                } else {
                    upper = max(value, lower + minGap)
                }
            }
    }

    /// 把轨道上的横向坐标换算成数值
    private func value(at x: CGFloat, trackWidth: CGFloat) -> Int {
        let span = CGFloat(bounds.upperBound - bounds.lowerBound)
        let raw = (x - handleSize / 2) / trackWidth
        return bounds.lowerBound + Int((min(max(raw, 0), 1) * span).rounded())
    }

    /// 距离锚点足够近时吸附到锚点，否则保持原值
    private func snapped(_ value: Int, anchors: [Int]) -> Int {
        guard let nearest = anchors.min(by: { abs($0 - value) < abs($1 - value) }) else {
            return value
        }
        return abs(nearest - value) <= snapTolerance ? nearest : value
    }

    /// 把数值换算成轨道上的横向比例（0-1）
    private func ratio(for value: Int) -> CGFloat {
        let span = CGFloat(bounds.upperBound - bounds.lowerBound)
        guard span > 0 else { return 0 }
        return CGFloat(value - bounds.lowerBound) / span
    }
}
