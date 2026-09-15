//
//  ContentView.swift
//  pm_worker
//
//  Created by 陈晓峰 on 2026/9/10.
//

import SwiftUI

/// 根视图 —— 三栏主界面（左栏三级导航 / 中栏工作区 / 右栏四 Tab 面板），横向并排。
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 三个内容区块横向并排（左导航 / 中工作区 / 右面板），各块内部沿垂直方向
        // 展开、占满所在列高度；窗口标题栏已隐藏（.windowStyle(.hiddenTitleBar)），
        // 页面顶部无任何标题栏与横条导航。
        // 全出血关键点：HSplitView 桥接 NSSplitView，每个 pane 是独立 NSHostingView，
        // 外层 ignoresSafeArea 的扩张不会传播进 pane（pane 重新继承窗口顶部安全区，
        // Tahoe 上 hiddenTitleBar 窗口顶部 inset 非 0）——各 pane 在各自根部决定
        // 顶部策略：左栏（自绘窗口控制钮）与右栏（tabs 紧凑间距）根部忽略贴顶；
        // 中栏按路由在 middlePane 内部决定（对话页贴顶 / 功能导航整页尊重安全区）。
        HSplitView {
            ProjectSidebar(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                .sidebarVibrancy()
                // 顺序关键：ignoresSafeArea 必须放在 frame/背景**之后**（最外层）。
                // 放在前面时扩张会被 HSplitView 的 pane 布局吃掉——内容仍从顶部
                // 安全区(31pt)开始，露出 hosting 白底，形成顶部白条色差。
                .ignoresSafeArea(.container, edges: .top)

            // 中栏：顶部安全区策略在 middlePane 内部按路由决定（对话页全出血 /
            // 功能导航整页尊重顶部安全区）。策略必须放在 pane **内部**而非直接
            // 分支 pane 本身——HSplitView 子级保持单一结构身份，路由切换不重建
            // split item（否则分割条位置被重置）。
            middlePane

            // 原型 v4 App Shell：右栏四 Tab 面板只在对话 / 新建任务等上下文页
            // 渲染；技能库 / 知识库 / 决策日志为独立整页（不挂 RightPanel）。
            // 收起后整栏退出布局（展开钮见上方中栏悬浮 overlay）。
            if showsInspectorPanel, !model.inspectorCollapsed {
                InspectorPanel()
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                    .background(Color.surfaceSecondary)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        // 隐藏系统红绿灯与顶部安全区占位，左上角改由侧栏自绘窗口控制按钮接管
        .background(WindowChromeConfigurator())
        // 隐藏标题栏后仍保留的顶部安全区会让三栏内容整体下坠，忽略顶部安全区
        // 让内容贴到窗口顶缘（侧栏首行即自绘窗口控制按钮，右栏 tabs 恢复紧凑间距）。
        .ignoresSafeArea(.container, edges: .top)
        // 设置弹框（Trae 风格模态）：全窗口遮罩 + 居中弹框，Esc / 点遮罩关闭
        .overlay {
            if model.settingsPresented {
                SettingsDialogOverlay()
                    .transition(.opacity)
            }
        }
        .animation(DS.Motion.springFast, value: model.settingsPresented)
        // 窗口级瞬态通知：顶部居中（侧栏删除/重命名/新建版本等操作反馈）。
        // 侧栏 pane 宽度只有 220–320pt，在其内部弹通知必然偏居一侧。
        .dsNotifCenter($model.notif, alignment: .top)
    }

    /// 功能导航三页（技能库 / 知识库 / 决策日志）为独立整页——只展示
    /// 自己的内容，收起右栏（对齐原型 v4：RightPanel 仅对话 / 新建任务渲染）。
    private var showsInspectorPanel: Bool {
        switch model.selection {
        case .skillLibrary, .knowledgeHub, .decisionsPage: false
        default: true
        }
    }

    /// 中栏 pane 骨架（frame / 背景 / 动效）。顶部安全区策略按路由在内部决定：
    /// - 对话上下文页（挂右栏）：全出血 ignoresSafeArea——顶栏自绘 chrome 贴窗口
    ///   顶缘（overlay 挂在 ignoresSafeArea **内侧**，对齐基准含顶部扩张，展开钮
    ///   与左栏首行零错位）；
    /// - 功能导航整页（技能库 / 知识库 / 决策日志）：**尊重顶部安全区**——Tahoe 上
    ///   hiddenTitleBar 窗口保留 ~31pt 标题栏工具区，macOS 会在该区域绘制材质 /
    ///   滚动边带，整页 ScrollView 全出血时 hero 标题滚入区域即被遮挡（实测截图）；
    ///   与独立窗口（真实标题栏）同构：内容从安全区下方开始，页面背景经
    ///   background(_:ignoresSafeAreaEdges:) 默认全边延伸，顶缘无色差。
    private var middlePane: some View {
        Group {
            if showsInspectorPanel {
                middle
                    // 右栏收起态：悬浮展开钮叠在中栏右上角（不占布局宽度，参考图形制）。
                    // 顺序关键：overlay 必须挂在 ignoresSafeArea **内侧**——挂外侧时
                    // 对齐基准是未含顶部安全区扩张的 frame，按钮被顶部 inset 整体压下，
                    // 与左栏首行（贴顶 8pt）横向错位。
                    .overlay(alignment: .topTrailing) {
                        if model.inspectorCollapsed {
                            InspectorExpandButton()
                                // 与展开态面板头部收起钮同一垂直位：该钮 = top 10 + 行高 32
                                // （DSTabs 28+4）中 24pt 盒居中 → 图标中心 26pt；本钮 28pt 盒
                                // top 12 → 中心同为 26pt，两态切换按钮零跳动。
                                .padding(.top, DS.Spacing.s12)
                                .padding(.trailing, DS.Spacing.s12)
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                middle
            }
        }
        .frame(minWidth: 480)
        .frame(maxWidth: .infinity)
        .background(Color.surfaceBase)
        .animation(DS.Motion.springFast, value: model.inspectorCollapsed)
    }

    /// 中栏工作区：按 model.selection 路由（新建任务 / 项目主页 / 会话 /
    /// 功能导航三页：技能库 / 知识库 / 决策日志，原型 v4 Sidebar NAV。
    /// 模型配置与 MCP 设置在设置弹框（侧栏左下角齿轮 / ⌘,）。
    @ViewBuilder
    private var middle: some View {
        switch model.selection {
        case .newTask:
            NewTaskView()
        case .projectHome(let project):
            ProjectHomeView(projectName: project) { version in
                Task { await model.releaseVersion(project: project, version: version) }
            }
        case .session(let project, let version, let sessionId):
            ConversationView(
                model: model, project: project, version: version, sessionId: sessionId
            )
        case .skillLibrary:
            SkillLibraryView()
        case .knowledgeHub:
            CardLibraryView()
        case .decisionsPage:
            DecisionLogPage()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
