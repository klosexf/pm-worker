//
//  DS.swift
//  pm_worker
//
//  TraeWork 设计令牌（视觉还原 Wave 1 + 深色模式系统）：
//  从交互原型 v4 内联的 colors_and_type.css 全量翻译——色板 / 字体 / 间距 / 圆角。
//  深色模式（2026-09-12）：令牌改 NSColor dynamicProvider 双值动态色——
//  浅色值逐值保真（与原型 v4 / 既有实现零偏差），深色值为新增设计
//  （冷调紫染深灰阶，对比度按 WCAG AA 校验）。
//
//  命名对照原型 CSS 变量：
//    --bg-brand → Color.brand600（色阶 50-700）
//    --text-default/secondary/tertiary/disabled → ink900/700/500/300
//    --bg-base-* → surfaceBase/Secondary/Tertiary；--bg-overlay-l1-l4 → overlayL1-L4
//    --bg-invert → ink950 系（原型 primary 按钮是深反色，非品牌紫）
//    --border-neutral-l1/l2/l3 → borderL1/L2/L3；--status-* → statusPrimary 等 + surface 变体
//

import SwiftUI
import AppKit

// MARK: - 动态色工厂

// nonisolated：令牌初始化器与解析器（MarkdownParser.inline 等 nonisolated 上下文）
// 都要取用——NSColor dynamicProvider 构造线程安全，非隔离声明可被任意上下文访问。
nonisolated extension Color {
    /// 深浅双值动态色（不透明）：NSColor dynamicProvider 承载，
    /// 随窗口 / 系统外观切换自动重解析，调用点无需感知模式。
    static func dynamic(_ lightHex: UInt32, _ darkHex: UInt32) -> Color {
        dynamic(lightHex, 1, darkHex, 1)
    }

    /// 深浅双值动态色（各自独立透明度：浅色多与原型逐值对齐，
    /// 深色按暗底可见性上调 alpha——如选中底 / 遮罩 / 状态浅底）。
    static func dynamic(
        _ lightHex: UInt32, _ lightAlpha: Double,
        _ darkHex: UInt32, _ darkAlpha: Double
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let (hex, alpha) = isDark ? (darkHex, darkAlpha) : (lightHex, lightAlpha)
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(alpha)
            )
        })
    }
}

// MARK: - 颜色令牌

nonisolated extension Color {
    // 品牌：填充系（500 hover / 600 默认 / 700 active）深色换用原型 Dark 的
    // --bg-brand/-hover/-active（#5A50F0 系，暗底抬亮）；色阶 50-200 是「浅紫薄底」
    // 系，深色换成亮紫半透明（原型 Dark 的薄底一律走 --bg-brand-popup 语义）。
    static let brand50 = Color.dynamic(0xF2F7FF, 1, 0x7A75FF, 0.12)
    static let brand100 = Color.dynamic(0xE5EAFF, 1, 0x7A75FF, 0.16)
    static let brand200 = Color.dynamic(0xCFD8FF, 1, 0x7A75FF, 0.40)
    static let brand300 = Color(red: 0xAA / 255, green: 0xB7 / 255, blue: 0xFF / 255)
    static let brand400 = Color(red: 0x88 / 255, green: 0x94 / 255, blue: 0xFF / 255)
    static let brand500 = Color.dynamic(0x6A6FFF, 0x6F63FF)   // hover
    static let brand600 = Color.dynamic(0x4B3FE3, 0x5A50F0)   // 默认（Dark --bg-brand）
    static let brand700 = Color.dynamic(0x3F31C6, 0x4C3FD6)   // active

    /// 品牌强调前景（文字 / 图标）：浅色 = brand600；深色 = 原型 --text-brand #9491FF
    ///（brand600 直接作暗底文字对比度不足，原型 Dark 单设 text-brand 语义）。
    /// 与 brand600（填充 / 按钮底，白字成立）职责分离。
    static let brandAccent = Color.dynamic(0x4B3FE3, 0x9491FF)

    // 反色（--bg-invert：原型 primary 按钮的深底）。原型 Dark 的 invert 仍是深底
    // #32323A（白字 text-white）——「反色」指对 base 反差，不是深色下反转成亮底。
    static let invert = Color.dynamic(0x27262D, 0x32323A)
    static let invertHover = Color.dynamic(0x42414A, 0x45454F)
    static let invertActive = Color.dynamic(0x18171E, 0x26262E)
    /// invert 底上的前景（primary 按钮文字）：双模式恒白（原型 --text-white）。
    static let onInvert = Color.dynamic(0xFFFFFF, 0xFFFFFF)
    static let ink800 = Color.dynamic(0x42414A, 0xB4B4BE)

    // 文字（--text-default / secondary / tertiary / disabled；深色逐值对齐原型 Dark）
    static let ink900 = Color.dynamic(0x1A1921, 0xE8E8EC)
    static let ink700 = Color.dynamic(0x43424B, 0x9A9AA3)
    static let ink500 = Color.dynamic(0x747480, 0x7E7E8A)
    static let ink300 = Color.dynamic(0xA3A3AD, 0x55555F)

    /// 用户气泡底（浅色沿袭 ink900 旧实现值；深色 = 原型 Dark userBubble --bg-invert
    /// #32323A）。字色恒白（浅 surfaceBase 白 / 深 --text-white 白）。
    static let userBubble = Color.dynamic(0x1A1921, 0x32323A)

    // 表面（--bg-base-*；深色逐值对齐原型 Dark：
    // default #0D0D0F / secondary #161618 / tertiary #050507 凹槽更深）
    static let surfaceBase = Color.dynamic(0xFFFFFF, 0x0D0D0F)
    static let surfaceSecondary = Color.dynamic(0xF5F5F8, 0x161618)
    static let surfaceTertiary = Color.dynamic(0xE5E5EA, 0x050507)

    /// 微染中性灰（overlay/border 阶梯浅色基色：hue 偏品牌紫 ~250°）。
    /// 深色下 overlay/border 阶梯已在下方逐值显式定义为白系微透明（原型 Dark 直供），
    /// 此值仅作 disabled 底等零散直接用点的基色。
    static let tintGray = Color.dynamic(0x555463, 0xFFFFFF)

    // 交互 overlay 阶梯（深色 = 原型 Dark 白系微透明；L4 = 遮罩黑 55%）
    static let overlayL1 = Color.dynamic(0x555463, 0.08, 0xFFFFFF, 0.05)
    static let overlayL2 = Color.dynamic(0x555463, 0.12, 0xFFFFFF, 0.09)
    static let overlayL3 = Color.dynamic(0x555463, 0.16, 0xFFFFFF, 0.14)
    static let overlayL4 = Color.dynamic(0x555463, 0.20, 0x000000, 0.55)

    // 边框（--border-neutral-l1/l2/l3；深色 = 原型 Dark 白系 8%/14%/30%）
    static let borderL1 = Color.dynamic(0x555463, 0.10, 0xFFFFFF, 0.08)
    static let borderL2 = Color.dynamic(0x555463, 0.16, 0xFFFFFF, 0.14)
    static let borderL3 = Color.dynamic(0x555463, 0.34, 0xFFFFFF, 0.30)

    /// 阴影墨色：双模式统一近黑。深色光晕语义已退役（2026-09-12 Xcode 质感
    /// P0-③）——深色分层靠「黑影 + 白发丝描边」，浅色光晕只合法于焦点环，
    /// 用作投影会有霓虹感。浅色保持 ink900 浅值，既有观感零变化。
    static let shadowInk = Color.dynamic(0x1A1921, 0x000000)

    /// 模态遮罩：浅色 ink900@24%（原实现）；深色 = 原型 --bg-overlay-l4 黑@55%。
    static let scrim = Color.dynamic(0x1A1921, 0.24, 0x000000, 0.55)

    /// 焦点对比边（原型 --border-contrast）：浅色黑 / 深色白——输入框聚焦描边。
    static let contrastBorder = Color.dynamic(0x000000, 0xFFFFFF)

    /// 弹层描边（P1-④：阴影降档后暗底浮层的分层线）：浅色同 borderL1；
    /// 深色抬到白@12%——黑影上 8% 发丝不足以勾出浮层轮廓（DSMenu / 记忆抽屉）。
    static let overlayBorder = Color.dynamic(0x555463, 0.10, 0xFFFFFF, 0.12)

    // 状态色（--status-*-default；深色逐值对齐原型 Dark 抬亮档）
    static let statusPrimary = Color.dynamic(0x2F74FF, 0x6CA0FF)
    static let statusSuccess = Color.dynamic(0x15A877, 0x3DD68C)
    static let statusAlert = Color.dynamic(0xFEA900, 0xFFC53D)
    static let statusWarning = Color.dynamic(0xE27900, 0xFFA23E)
    static let statusError = Color.dynamic(0xE8463A, 0xFF7A70)

    // 状态浅底（--status-*-surface-l1；深色 = 原型 Dark l1 档 alpha）
    static let statusPrimarySurface1 = Color.dynamic(0x2F74FF, 0.12, 0x6CA0FF, 0.14)
    static let statusSuccessSurface1 = Color.dynamic(0x40B08B, 0.12, 0x3DD68C, 0.14)
    static let statusAlertSurface1 = Color.dynamic(0xFEA900, 0.14, 0xFFC53D, 0.15)
    static let statusWarningSurface1 = Color.dynamic(0xE27900, 0.12, 0xFFA23E, 0.14)
    static let statusErrorSurface1 = Color.dynamic(0xE8463A, 0.12, 0xFF7A70, 0.14)

    /// 品牌选中底（--bg-brand-popup）：浅色淡紫 36%；深色 = 原型 rgba(122,117,255,0.20)。
    static let brandPopup = Color.dynamic(0xAAB7FF, 0.36, 0x7A75FF, 0.20)

    // 对话输入框（Composer · 参考 Trae 输入卡 · WCAG 2.1 AA 对比度校验）：
    /// 输入卡表面：浅色纯白（与页面同底，靠描边 + 阴影分层）；深色比 base（#0D0D0F）
    /// 抬亮一档 #161618（参考图浮起卡语义，同 surfaceSecondary 深值）。
    static let composerSurface = Color.dynamic(0xFFFFFF, 0x161618)
    /// 占位文字：浅 #747480（白底 4.6:1）/ 深 #8A8A94（#161618 底 5.3:1）——AA ≥ 4.5:1。
    /// ink300 双模式仅 ≈2.5:1，只能作装饰图形，不能承载占位文字。
    static let composerPlaceholder = Color.dynamic(0x747480, 0x8A8A94)
}

// MARK: - 外观模式（深色模式切换系统）

/// 外观偏好（设置 → 通用）：跟随系统 / 浅色 / 深色。
/// 持久化走 UserDefaults（@AppStorage）——UI 偏好不入 ~/PMAgent 产品数据目录。
/// nonisolated：值模型（默认 MainActor 隔离下 Identifiable/Hashable 合成会踩隔离坑）。
nonisolated enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "pm.worker.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// preferredColorScheme 期望值（跟随系统 = nil，不覆盖系统外观）。
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// AppKit 应用级外观名（NSApplication.shared.appearance）。跟随系统 = nil（清除覆盖，随系统切换）。
    var appKitAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// 应用级外观覆盖（幂等）。macOS 26 上 .preferredColorScheme 不会真正改变
    /// NSWindow.effectiveAppearance（DS 令牌 / vibrancy / popover 全不跟随），
    /// 改以应用级 appearance 为单一事实源：覆盖所有窗口与浮层，全链路生效。
    /// 注意用 NSApplication.shared 而非 NSApp：App.init 阶段 NSApp 全局指针尚未初始化（nil IUO，取用即崩）。
    /// @MainActor：枚举本体 nonisolated（值模型隔离坑），但 NSApplication.shared
    /// 是 MainActor 隔离的——写 appearance 必须回主隔离域；调用点均在主线程。
    @MainActor
    static func applyAppKitAppearance(_ raw: String?) {
        let mode = AppearanceMode(rawValue: raw ?? "") ?? .system
        NSApplication.shared.appearance = mode.appKitAppearanceName.flatMap { NSAppearance(named: $0) }
    }

    /// 外观偏好变更广播。**视图侧只订阅这条自定义通知，绝不观察 UserDefaults**：
    /// SwiftUI 的 WindowGroup 在每次窗口 resize（frame 自动保存）时都会写
    /// UserDefaults 并同步派发 didChangeNotification，任何 UserDefaults 观察
    /// （@AppStorage / didChangeNotification）都会逐帧触发一次 CFPreferences
    /// search-list 合并读取（采样实测占 resize 每帧成本一半以上——拖拽边框卡顿主因）。
    static let changedNotification = Notification.Name("pm.worker.appearance.changed")

    /// 当前持久化偏好（只在窗口构建 / 设置弹框初始化时读，热路径不读）。
    static func currentRawValue() -> String {
        UserDefaults.standard.string(forKey: storageKey) ?? AppearanceMode.system.rawValue
    }

    /// 唯一写入路径：持久化 + 应用外观 + 广播（设置弹框改外观走这里）。
    @MainActor
    static func setAppearance(_ raw: String) {
        let mode = AppearanceMode(rawValue: raw) ?? .system
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
        applyAppKitAppearance(mode.rawValue)
        NotificationCenter.default.post(name: changedNotification, object: mode.rawValue)
    }
}

/// 外观应用修饰符：读外观偏好 → 驱动应用级 appearance（NSApplication.shared）+ 切换过渡动画（0.28s 交叉淡化）。
/// 四个窗口根统一挂载（pm_workerApp），设置弹框写同一 UserDefaults 键即时全局生效。
///
/// 为什么不用 .preferredColorScheme：macOS 26 实测它只改 SwiftUI 环境 colorScheme，
/// **不会真正改变 NSWindow.effectiveAppearance**——DS 令牌（NSColor 动态解析）、
/// 侧栏 vibrancy 材质、popover 全部不跟随，设置形同虚设（2026-09-12 运行时截图复现：
/// defaults 写 dark 启动仍全浅色）。改用 AppKit 单一事实源 NSApplication.shared.appearance：
/// 应用级覆盖所有窗口（含后开窗口）与浮层，材质/动态颜色/环境 colorScheme 全链路生效。
private struct AppAppearanceModifier: ViewModifier {
    /// 外观偏好镜像：初值在窗口构建时读一次，之后只跟着自定义通知走——
    /// **热路径（resize 每帧重算 body）零 UserDefaults 读取**。
    /// 反面教材见 AppearanceMode.changedNotification 注释：直接观察 UserDefaults
    /// 会被 SwiftUI 的窗口 frame 自动保存逐帧唤醒，每次读取走 CFPreferences
    /// search-list 合并慢路径，是拖拽边框卡顿的主因。
    @State private var rawValue: String = AppearanceMode.currentRawValue()

    func body(content: Content) -> some View {
        content
            // rawValue 变化 → 窗口外观切换 → 令牌重解析 → 子树颜色交叉淡化（非颜色属性不受影响）
            .animation(.easeInOut(duration: 0.28), value: rawValue)
            .onAppear { AppearanceMode.applyAppKitAppearance(rawValue) }
            .onReceive(
                NotificationCenter.default.publisher(for: AppearanceMode.changedNotification)
            ) { note in
                guard let latest = note.object as? String else { return }
                rawValue = latest
            }
    }
}

extension View {
    /// 应用外观偏好（跟随系统 / 浅色 / 深色）+ 平滑切换过渡。窗口根调用一次。
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}

// MARK: - 间距 / 圆角 / 字体

enum DS {
    // 间距阶梯（--spacer-*，pt 与 px 1:1）
    enum Spacing {
        static let s0: CGFloat = 0
        static let s2: CGFloat = 2
        static let s3: CGFloat = 3
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40
        static let s48: CGFloat = 48
        /// 2026-09 对话呼吸感改版：轮与轮间距（HTML 方案 B+C 定稿值）。
        static let s52: CGFloat = 52
        static let s64: CGFloat = 64
    }

    // 圆角阶梯（--radius-*）
    enum Radius {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 10
        static let xxl: CGFloat = 12
        static let big: CGFloat = 16
        /// 2026-09 呼吸感改版新增（阶梯语义名之外的大圆角，数值自释）：
        /// 产物卡。
        static let r18: CGFloat = 18
        /// 用户气泡 / 输入坞。
        static let r20: CGFloat = 20
        static let full: CGFloat = 999
    }

    /// 字体（--body-* / --heading-*：SF Pro + PingFang 由系统字体栈自然满足）。
    /// 2026-09 高级感升级：body 系整体抬升一档（11-14 → 12-15），
    /// heading 大档拉大（17/22/28/34）配 .dsTight() 紧字距拉开层级对比。
    enum Font {
        // body 系（400/500）
        static let bodyXS = SwiftUI.Font.system(size: 12, weight: .regular)
        static let bodyXSStrong = SwiftUI.Font.system(size: 12, weight: .medium)
        static let bodySM = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodySMStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        static let bodyMD = SwiftUI.Font.system(size: 14, weight: .regular)
        static let bodyMDStrong = SwiftUI.Font.system(size: 14, weight: .medium)
        static let bodyBase = SwiftUI.Font.system(size: 15, weight: .regular)
        static let bodyBaseStrong = SwiftUI.Font.system(size: 15, weight: .medium)
        /// 对话注脚行（2026-09 呼吸感改版：摘要条降噪）。
        static let bodyFootnote = SwiftUI.Font.system(size: 12.5)
        /// 对话阅读字号（2026-09-13 方案 B「清晰梯度」：17 → 15 收敛正文——
        /// 17 与表格 15 并置是「忽大忽小」的根源之一；层级改由导语 / 章节 /
        /// 表格的收敛阶梯承担，见 DS.Typography 对话令牌组与 MarkdownText 映射。
        /// 对话流正文（AI 回答 Markdown / 用户气泡 / 输入框）专用）。
        static let chatBase = SwiftUI.Font.system(size: 15, weight: .regular)
        static let chatBaseStrong = SwiftUI.Font.system(size: 15, weight: .medium)
        static let bodyLG = SwiftUI.Font.system(size: 20, weight: .regular)

        // heading 系（600）
        static let heading2XS = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let headingXS = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let headingSM = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let headingMD = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let headingLG = SwiftUI.Font.system(size: 28, weight: .semibold)
        static let headingXL = SwiftUI.Font.system(size: 34, weight: .semibold)

        /// 编辑级衬线展示字（New York）：空态标题 / 项目主页 hero 专用——
        /// 与 SF Pro 正文形成杂志排版对比（Craft/Mela 式高级感）。
        static let displayMD = SwiftUI.Font.system(size: 21, weight: .semibold, design: .serif)
        static let displayLG = SwiftUI.Font.system(size: 34, weight: .semibold, design: .serif)
        /// 档案索引衬线小号（侧栏任务列表项目行 · 档案方案）：display 系最小档。
        static let display2XS = SwiftUI.Font.system(size: 15, weight: .semibold, design: .serif)
        /// 对话内 Markdown 章节标题（2026-09 呼吸感改版）：display 系中档。
        static let displaySM = SwiftUI.Font.system(size: 19, weight: .semibold, design: .serif)

        /// 等宽（--code-editor：JetBrains Mono 打包进 bundle · OFL 许可 ·
        /// pm_workerApp.init 显式注册；非拉丁字符自动级联系统字体（中文回落苹方））。
        static let mono = SwiftUI.Font.custom("JetBrainsMono-Regular", size: 13)
        /// 对话代码块字号（随 chatBase 15 同档：14 → 13，压缩与正文 15 的落差）。
        static let monoLG = SwiftUI.Font.custom("JetBrainsMono-Regular", size: 13)
        static let monoSM = SwiftUI.Font.custom("JetBrainsMono-Regular", size: 12)
        /// 档案索引 mono 小标签（01 索引 / VER / SEALED · 档案方案）。
        static let mono2XS = SwiftUI.Font.custom("JetBrainsMono-Regular", size: 11)
    }

    /// 动效令牌（高级感升级：spring 物理取代 ease 曲线——机械感是廉价感来源之一）。
    enum Motion {
        /// 标准微动效弹簧（≈320ms · 轻微回弹）：抽屉 / 分段胶囊 / 浮层过渡。
        static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// 快速反馈弹簧（≈200ms · 无过冲）：hover / 开关 / 展开。
        static let springFast = Animation.spring(response: 0.2, dampingFraction: 0.9)
    }

    /// 排版令牌（2026-09 编辑级方案；行距按用户阅读标准 1.2-1.5×size 校准）：
    /// SF Pro / 苹方默认行高 ≈1.2×size，lineSpacing = (ratio−1.2)×size，
    /// 参数随字号自然缩放 → 跨窗口尺寸 / 分辨率一致（响应式排版）。
    /// 调用点禁止再硬编码 lineSpacing 数值，一律走此令牌。
    enum Typography {
        /// 正文行高比例（含字体默认 1.2 基线）：中文长读紧凑舒适档（用户标准 1.2-1.5 内偏紧，
        /// 配合宽松段距形成「行密段疏」的专业阅读节奏）。
        static let bodyRatio: CGFloat = 1.45
        /// 辅助 / 说明文字行高比例：短文本略紧一档。
        static let captionRatio: CGFloat = 1.4
        /// 表格单元格行高比例：短文本紧凑档。
        static let tableRatio: CGFloat = 1.45
        /// 中文正文微字距（+0.2）：字与字之间轻微透气，去挤压感。
        static let bodyTracking: CGFloat = 0.2
        /// 段落间距（Markdown block 间）：2026-09-15 方案 A「阅读栏 · 刻度阶梯」
        /// 18 → 22——段距须显著大于行距，否则段落粘连成一整块文字墙。
        ///（排版节奏值，非布局网格——不在 DS.Spacing 阶梯内）
        static let paragraphSpacing: CGFloat = 22
        /// Markdown 标题上方额外间距（叠加在 paragraphSpacing 之上 → 实得 34）：
        /// 标题「上远下近」倒挂节奏——远离上文、贴近所辖内容。
        static let headingTop: CGFloat = DS.Spacing.s12
        /// Markdown 标题下方间距（方案 A 新增）：实得 34 : 8 ≈ 4:1 的倒挂比，
        /// 标题明确贴住它所辖的内容。
        static let headingBottom: CGFloat = DS.Spacing.s8
        /// 列表行间距。
        static let listRowSpacing: CGFloat = DS.Spacing.s6
        /// 列表悬挂缩进（方案 A 新增）：标记列定宽，文本列自 22 起排——
        /// 换行回到文本列而不是第 0 列，长条目才读得成「一条」。
        static let listHangingIndent: CGFloat = 22

        // 对话 Markdown 排版（2026-09-13 方案 B「清晰梯度」→ 2026-09-15 呼吸感改版
        // → 2026-09-15 方案 A「阅读栏 · 刻度阶梯」）：层级 = 字级刻度阶梯 + 样式差
        // 协同 + 阅读栏宽——26 / 21 衬线章节 / 17 / 15 条目标题 / 13 小节标签 /
        // 15 正文 / 13.5 表格 / 12.5 行内代码 / 13 代码块。
        // 规则：相邻可见级差 ≥2pt 且必伴一样样式差（衬线在 h3 退场、刻度线随 h4、
        // 颜色 / 字重）。
        /// 对话正文行高比例（呼吸感改版 1.62 → 1.78；方案 A 1.78 → 1.72——
        /// 行宽收窄到阅读栏后行数增多，行距略收，整段高度不至于失控）。
        static let chatRatio: CGFloat = 1.72
        /// 对话正文阅读栏宽度上限（方案 A 新增）：散文（标题 / 段落 / 列表 / 引用 /
        /// 分隔线）自适应宽度 640——CJK ≈42 字。列宽 720 时每行约 48 字，超出
        /// 30–40 字舒适区，回行容易丢行。表格 / 代码 / 图表不入阅读栏（数据块需要
        /// 横向空间）——「读的」与「看的」两条宽度线。
        static let chatMeasure: CGFloat = 640
        /// 导语 / 结论行（消息首段含加粗）。
        static let chatLeadSize: CGFloat = 16
        /// 标题字级阶梯（h1…h6，方案 A「刻度阶梯」）：h1 / h2 衬线章节标题，
        /// h3 起退场回无衬线条目档。取代原 chatHeadingSize（h1–h4 同为 19——
        /// AI 大量使用 ## 与 ###，排出来却分不出「章」与「条」）。
        static let chatHeadingLadder: [CGFloat] = [26, 21, 17, 15, 13, 13]
        /// 小节标签（h5 / h6，次级色）。
        static let chatLabelSize: CGFloat = 13
        /// 表格单元格字号（表头再小一档）。
        static let chatTableSize: CGFloat = 13.5
        /// 表格表头字号（semibold + 小号 = 小标签气质）。
        static let chatTableHeaderSize: CGFloat = 12.5

        /// 行间距换算：目标行高比例 → SwiftUI lineSpacing 值。
        static func leading(for size: CGFloat, ratio: CGFloat = bodyRatio) -> CGFloat {
            max(0, (ratio - 1.2) * size)
        }
    }
}

// MARK: - 排版修饰符（行高 / 字距令牌出口）

extension Text {
    /// 编辑级正文排版：中文微字距 + 行高比例（默认全局 1.45；对话流传
    /// DS.Typography.chatRatio）。须在 textSelection 等 View 修饰符之前链
    ///（tracking 是 Text 专有方法）。
    func dsBodyType(size: CGFloat, ratio: CGFloat = DS.Typography.bodyRatio) -> some View {
        tracking(DS.Typography.bodyTracking)
            .lineSpacing(DS.Typography.leading(for: size, ratio: ratio))
    }

    /// 辅助 / 说明文字排版：行高 1.6、零字距（多行 caption 场景）。
    func dsCaptionType(size: CGFloat) -> some View {
        lineSpacing(DS.Typography.leading(for: size, ratio: DS.Typography.captionRatio))
    }
}

// MARK: - 高度令牌（Xcode 纪律：窗内零影，投影只属于模态）

/// 浮起层级：贴地卡片 < 浮层 < 弹框 < 输入坞。
enum DSElevation { case card, floating, overlay, dock }

extension View {
    /// 分层阴影（2026-09-12 Xcode 质感 P0-③ 降档）：窗内内容零投影——层次由
    /// 表面灰阶 + 发丝线承担（.card = 无影）；浮层只留若有若无的环境影；
    /// 投影是模态（弹框 / 菜单 / 抽屉）的专利，且一律近黑单影（shadowInk），
    /// 深色下靠白发丝描边分层。「克制」是专业感的来源。
    @ViewBuilder
    func dsShadow(_ level: DSElevation) -> some View {
        switch level {
        case .card:      // 贴地卡片：零影——发丝线 + 灰阶分层（Xcode 窗内纪律）
            self
        case .floating:  // 浮层（通知条 / 确认坞）：极轻环境影
            shadow(color: Color.shadowInk.opacity(0.05), radius: 8, y: 2)
        case .overlay:   // 弹框 / 抽屉 / 菜单（最强层级）：单一黑影
            shadow(color: Color.shadowInk.opacity(0.22), radius: 16, y: 6)
        case .dock:      // 输入坞 / 大浮层：双层大软阴影（2026-09 呼吸感改版，
                         // 参数沿 DSMenu 原型投影 0 12/32 12% + 0 2/8 8%）
            self
                .shadow(color: Color.shadowInk.opacity(0.12), radius: 32, y: 12)
                .shadow(color: Color.shadowInk.opacity(0.08), radius: 8, y: 2)
        }
    }
}

extension Text {
    /// 大标题紧字距（≈-0.02em）：headingLG/XL 与 display 系标配。
    func dsTight() -> Text { tracking(-0.6) }
}

// MARK: - 动效修饰符（fadein / slidein：200ms · 位移 ≤4px · 尊重 reduced-motion）

extension View {
    /// 原型 .fadein：透明度 0→1 + 上移 3px。
    func dsFadeIn() -> some View {
        modifier(DSFadeSlideTransition(horizontal: false))
    }

    /// 原型 .slidein：透明度 0→1 + 右移 4px。
    func dsSlideIn() -> some View {
        modifier(DSFadeSlideTransition(horizontal: true))
    }
}

private struct DSFadeSlideTransition: ViewModifier {
    let horizontal: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(
                x: shown || reduceMotion ? 0 : (horizontal ? 4 : 0),
                y: shown || reduceMotion ? 0 : (horizontal ? 0 : 3)
            )
            .onAppear {
                guard !reduceMotion else {
                    shown = true
                    return
                }
                withAnimation(DS.Motion.springFast) { shown = true }
            }
    }
}
