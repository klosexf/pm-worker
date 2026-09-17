//
//  WindowChromeTests.swift
//  pm_workerTests
//
//  窗口外观配置（WindowChromeConfigurator）的防回归锚点。
//
//  背景（2026-09-15 拖拽卡顿专项）：窗口 resize 每帧的开销里，一半以上来自
//  SwiftUI（WindowGroup 自动挂的）frame 自动保存——每次 setFrame 里
//  _persistFrame → saveFrame → 写 UserDefaults → cfprefsd IPC 往返。
//  关掉它（清空 frameAutosaveName）+ 视图树不再观察 UserDefaults 后，
//  逐帧成本 16ms → 8.9ms。改洞见落地在 WindowControls.swift / DS.swift 注释里，
//  本文件只钉住「配置结果」这一可断言的部分。
//

import XCTest
import AppKit
@testable import pm_worker

final class WindowChromeTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
    }

    /// 核心锚点：必须清空 SwiftUI 挂上的 frame 自动保存名。
    /// 漏掉这行 = 拖动边框每帧一次 UserDefaults 落盘 + cfprefsd 往返（卡顿回潮）。
    func testConfigureDisablesPerFrameFrameAutosave() {
        let window = makeWindow()
        window.setFrameAutosaveName("pmw.tests.autosave")
        XCTAssertFalse(window.frameAutosaveName.isEmpty, "前置条件：自动保存名已挂上")

        WindowChromeConfigurator.configure(window)

        XCTAssertTrue(
            window.frameAutosaveName.isEmpty,
            "必须清空 frameAutosaveName——SwiftUI 逐帧 saveFrame 是拖拽卡顿主因"
        )
    }

    /// 全出血窗口形态：隐藏标题栏 / 透明标题栏 / fullSizeContentView + 三枚
    /// 系统按钮隐藏（改由侧栏自绘窗口控制钮接管）。
    func testConfigureAppliesFullBleedChrome() {
        let window = makeWindow()

        WindowChromeConfigurator.configure(window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "内容铺满窗口")
        XCTAssertTrue(window.titlebarAppearsTransparent, "标题栏透明")
        XCTAssertEqual(window.titleVisibility, .hidden, "标题隐藏")
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(kind)?.isHidden, true, "系统红绿灯隐藏")
        }
    }

    /// 幂等：SwiftUI 每次更新都会回调（resize 期间每帧一次），重复调用必须保持
    /// 终态一致且不撤回已生效的配置。
    func testConfigureIsIdempotent() {
        let window = makeWindow()
        window.setFrameAutosaveName("pmw.tests.autosave")

        WindowChromeConfigurator.configure(window)
        WindowChromeConfigurator.configure(window)
        WindowChromeConfigurator.configure(nil)

        XCTAssertTrue(window.frameAutosaveName.isEmpty)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    /// 外观偏好走「唯一写入路径 + 自定义通知广播」：视图侧据此更新镜像，
    /// 不再观察 UserDefaults（反之会被窗口 frame 自动保存逐帧唤醒走
    /// CFPreferences 慢路径——见 DS.swift 注释）。
    func testSetAppearancePersistsAndBroadcasts() {
        let original = AppearanceMode.currentRawValue()
        defer { AppearanceMode.setAppearance(original) }

        let received = expectation(description: "changedNotification 广播")
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceMode.changedNotification, object: nil, queue: .main
        ) { note in
            XCTAssertEqual(note.object as? String, AppearanceMode.dark.rawValue)
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        AppearanceMode.setAppearance(AppearanceMode.dark.rawValue)

        wait(for: [received], timeout: 1)
        XCTAssertEqual(AppearanceMode.currentRawValue(), AppearanceMode.dark.rawValue, "已持久化")
    }
}