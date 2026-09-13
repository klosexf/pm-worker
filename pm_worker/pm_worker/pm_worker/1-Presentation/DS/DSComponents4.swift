//
//  DSComponents4.swift
//  pm_worker
//
//  TraeWork 组件库（视觉还原补齐 Wave 4）：原型剩余三组件的 SwiftUI 等价物。
//  · DSSelect（.ds-select）：32 高下拉——DS 视觉触发器 + 原生 Menu 弹层
//  · DSSlider（.ds-slider）：4px 轨道 + 14px 白底描边圆 thumb 自绘滑杆
//  · DSCode（.ds-code）：overlay-l1 底源码块（mono 13/20 · 可选中复制）
//

import SwiftUI

// MARK: - 下拉选择（.ds-select）

/// 选项：值 + 展示标题（nonisolated：值类型防隐式 MainActor）。
nonisolated struct DSSelectOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// 原型 .ds-select：32 高 · 白底 · neutral-l1 边框 r8 · 右缘下拉箭头 ·
/// 聚焦黑边（以 Menu 打开态近似）；disabled = 灰底 disabled 字色。
/// 弹层用原生 Menu——NSMenu 毛玻璃卡即原型 ds-menu 质感的 macOS 对应物，
/// 自带键盘导航 / 长列表滚动 / 点击外部关闭，且无父级 ScrollView 裁剪问题。
struct DSSelect<Value: Hashable>: View {
    let options: [DSSelectOption<Value>]
    @Binding var selection: Value

    @Environment(\.isEnabled) private var isEnabled

    init(options: [DSSelectOption<Value>], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? "—"
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack(spacing: DS.Spacing.s8) {
                Text(currentTitle)
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(isEnabled ? Color.ink900 : Color.ink300)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                DSIcon(.down, size: 14)
                    .foregroundStyle(isEnabled ? Color.ink500 : Color.ink300)
            }
            .padding(.leading, DS.Spacing.s12)
            .padding(.trailing, DS.Spacing.s10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(isEnabled ? Color.surfaceBase : Color.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - 滑杆（.ds-slider）

/// 原型 .ds-slider：4px overlay-l3 轨道 · r-full · 14px 白底 neutral-l3
/// 描边圆 thumb（无投影）。拖动热区扩到 20 高；step 对齐在取值时完成。
struct DSSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.overlayL3)
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                Circle()
                    .fill(Color.surfaceBase)
                    .overlay(Circle().strokeBorder(Color.borderL3, lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .offset(x: fraction * max(geo.size.width - 14, 0))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = Self.value(
                            atX: gesture.location.x, width: geo.size.width,
                            range: range, step: step
                        )
                    }
            )
        }
        .frame(height: 20)
    }

    /// x 像素 → 值（thumb 半宽热区钳制；step 对齐；边界内收）。
    nonisolated static func value(
        atX x: CGFloat, width: CGFloat,
        range: ClosedRange<Double>, step: Double?
    ) -> Double {
        let usable = max(width - 14, 1)
        let span = range.upperBound - range.lowerBound
        let raw = range.lowerBound
            + min(max((x - 7) / usable, 0), 1) * span
        guard let step, step > 0, span > 0 else { return min(max(raw, range.lowerBound), range.upperBound) }
        let snapped = range.lowerBound
            + ((raw - range.lowerBound) / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

// MARK: - 源码块（.ds-code）

/// 原型 .ds-code：overlay-l1 底 · neutral-l1 边框 · r8 · padding 12/16 ·
/// mono 13/20 · 保留换行 · 可选中复制。不内滚——overflow 由外层 ScrollView 承担
///（调用点惯例：ScrollView { DSCode(...) }）。
struct DSCode: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.mono)
            .dsCaptionType(size: 13)
            .foregroundStyle(Color.ink900)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, DS.Spacing.s12)
            .padding(.horizontal, DS.Spacing.s16)
            .background(Color.overlayL1, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}
