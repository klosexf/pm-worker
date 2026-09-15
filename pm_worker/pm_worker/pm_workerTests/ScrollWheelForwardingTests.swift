//
//  ScrollWheelForwardingTests.swift
//  pm_workerTests
//
//  内联 mermaid 图卡（ScrollForwardingWebView，scrollable=false）的滚轮转发：
//  WKWebView 默认在 AppKit 层吞掉 scrollWheel 且不转发，光标悬停图卡上时
//  外层（.md 预览弹框 / 消息列表）永远滚不动。内联模式必须上抛响应链；
//  滚动模式（放大弹窗）滚轮归 HTML 内部滚动，不上抛。
//

import XCTest
import AppKit
import WebKit
@testable import pm_worker

final class ScrollWheelForwardingTests: XCTestCase {

    /// 记录 scrollWheel 是否沿响应链到达
    private final class RecordingResponder: NSResponder {
        var received = 0
        override func scrollWheel(with event: NSEvent) { received += 1 }
    }

    /// 合成一行滚动量的滚轮事件（鼠标滚轮 / 触摸板同走 scrollWheel 事件通道）
    private func makeScrollEvent() -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: -5, wheel2: 0, wheel3: 0
        )!
        return NSEvent(cgEvent: cg)!
    }

    func testInlineModeForwardsScrollWheelUpResponderChain() {
        let recorder = RecordingResponder()
        let webView = ScrollForwardingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            configuration: WKWebViewConfiguration()
        )
        webView.forwardsScrollWheel = true
        webView.nextResponder = recorder

        webView.scrollWheel(with: makeScrollEvent())
        XCTAssertEqual(recorder.received, 1, "内联模式滚轮必须上抛响应链（外层 ScrollView 接手）")
    }

    func testScrollableModeConsumesScrollWheelLocally() {
        let recorder = RecordingResponder()
        let webView = ScrollForwardingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            configuration: WKWebViewConfiguration()
        )
        webView.forwardsScrollWheel = false
        webView.nextResponder = recorder

        webView.scrollWheel(with: makeScrollEvent())
        XCTAssertEqual(recorder.received, 0, "滚动模式滚轮归 HTML 内部滚动，不得上抛")
    }
}
