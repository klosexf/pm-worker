//
//  pm_workerApp.swift
//  pm_worker
//
//  Created by 陈晓峰 on 2026/9/10.
//

import SwiftUI
import CoreText

/// 入口分流（design.md §7.1）：Claude Desktop / Cursor 配置直接指向本 App 可执行文件
/// 并在 args 追加 `--mcp-server`——检测到该参数则跑无头 MCP server（stdin/stdout），
/// 不启 GUI；否则正常进 SwiftUI 主界面。
@main
enum pm_workerEntry {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--mcp-server") {
            // 无头 MCP 模式：server 在全局执行器上跑，主线程常驻服务 GCD 主队列
            Task.detached { await MCPServerRunner.run() }
            dispatchMain()
        } else {
            pm_workerApp.main()
        }
    }
}

struct pm_workerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        registerBundledFonts()
        // 首帧前应用持久化外观（NSApp.appearance，跟随系统 = 清除覆盖），
        // 避免窗口以系统默认外观先画一帧再切换的闪色。
        AppearanceMode.applyAppKitAppearance(
            UserDefaults.standard.string(forKey: AppearanceMode.storageKey)
        )
    }

    /// 注册 bundle 内置字体（JetBrains Mono，OFL 许可）。Resources 根的 ttf
    /// macOS 通常会自动注册，这里显式注册保证确定性（幂等，重复注册仅返回错误码）。
    private func registerBundledFonts() {
        guard let url = Bundle.main.url(
            forResource: "JetBrainsMono-Regular", withExtension: "ttf"
        ) else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // 外观偏好（跟随系统 / 浅色 / 深色，设置 → 通用）：+ 品牌紫 tint
                .appAppearance()
                .tint(Color.brand600)
        }
        // Xcode 同款全出血窗口（Edge-to-Edge，无顶部安全区）：
        // .hiddenTitleBar = 声明式等价于 AppKit 的 styleMask(.fullSizeContentView)
        //   + titlebarAppearsTransparent + titleVisibility(.hidden)，顶部安全区 inset 归零，
        //   内容从窗口 frame 最顶缘开始布局；
        // 系统红绿灯由 ContentView 挂载的 WindowChromeConfigurator 隐藏，
        // 窗口控制改由侧栏首行自绘三色圆接管（WindowControlButtons）。
        // 默认窗口尺寸：1280×800，三栏布局首次打开不至于局促
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)

        // 卡片库（Task 4.7）：knowledge_points 全表浏览 + 注记时间线 + 来源跳转
        Window("卡片库", id: "card-library") {
            CardLibraryView()
                .environmentObject(model)
                .appAppearance()
                .tint(Color.brand600)
        }
        .defaultSize(width: 900, height: 520)

        // 技能库（Task 4.7）：skills 表浏览 + enabled 开关（原型 v4 整页单栏）
        Window("技能库", id: "skill-library") {
            SkillLibraryView()
                .environmentObject(model)
                .appAppearance()
                .tint(Color.brand600)
        }
        .defaultSize(width: 960, height: 520)

        // 开发者检查器（Task 4.6，⌘D）：token 构成 / 检索 trace / 分支记录 / 校准注入
        Window("开发者检查器", id: "developer-inspector") {
            DeveloperInspector()
                .environmentObject(model)
                .appAppearance()
                .tint(Color.brand600)
        }
        .defaultSize(width: 680, height: 580)

        // 设置改为 Trae 风格模态弹框（SettingsDialog，侧栏左下角齿轮入口），
        // 不再用系统 Settings 窗——⌘, 快捷键由「视图」菜单接管。
        .commands {
            // 视图菜单（Task 4.6/4.7）：知识面三窗口入口（openWindow 已开则聚焦）
            CommandMenu("视图") {
                Button("设置…") {
                    model.settingsPresented.toggle()
                }
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("卡片库") {
                    openWindow(id: "card-library")
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])

                Button("技能库") {
                    openWindow(id: "skill-library")
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])

                Divider()

                Button("开发者检查器") {
                    openWindow(id: "developer-inspector")
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
