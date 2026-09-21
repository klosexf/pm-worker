//
//  ScrollWheelForwardingTests.swift
//  pm_workerTests
//
//  内联 mermaid 图卡（ScrollForwardingWebView，scrollable=false）的滚轮转发：
//  WKWebView 默认在 AppKit 层吞掉 scrollWheel 且不转发，光标悬停图卡上时
//  外层（.md 预览弹框 / 消息列表）永远滚不动。内联模式必须上抛响应链；
//  滚动模式（放大弹窗）滚轮归 HTML 内部滚动，不上抛；
//  ⌘+滚轮改走缩放通道（MermaidZoomBridge.onWheelZoom），且不再被滚动消费。
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

    /// 合成滚轮事件（鼠标滚轮 / 触摸板同走 scrollWheel 事件通道）
    /// - Parameter wheel: 滚动量，负=向下、正=向上
    private func makeScrollEvent(command: Bool = false, wheel: Int32 = -5) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: wheel, wheel2: 0, wheel3: 0
        )!
        if command { cg.flags = [.maskCommand] }
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

    /// ⌘ + 滚轮（放大弹窗）→ 缩放通道，且不被内部滚动消费
    func testCommandWheelRoutesToZoomBridge() {
        let recorder = RecordingResponder()
        let bridge = MermaidZoomBridge()
        var deltas: [CGFloat] = []
        bridge.onWheelZoom = { deltas.append($0) }

        let webView = ScrollForwardingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            configuration: WKWebViewConfiguration()
        )
        webView.forwardsScrollWheel = false
        webView.zoomBridge = bridge
        webView.nextResponder = recorder

        webView.scrollWheel(with: makeScrollEvent(command: true, wheel: 5))
        XCTAssertEqual(deltas.count, 1, "⌘+滚轮必须转成缩放增量")
        XCTAssertEqual(recorder.received, 0, "缩放事件不得漏给滚动链")
        XCTAssertGreaterThan(deltas[0], 0, "向上滚 = 放大")
        // 5 行 × 0.1 增益 = 0.5 → 封顶 0.25（不同鼠标每格 delta 差一个数量级）
        XCTAssertEqual(deltas[0], 0.25, accuracy: 0.0001, "单事件缩放幅度封顶 25%")
    }

    /// 无 ⌘ 的普通滚轮不触发缩放（放大弹窗内仍由 HTML 自己滚）
    func testPlainWheelDoesNotZoom() {
        let bridge = MermaidZoomBridge()
        var fired = 0
        bridge.onWheelZoom = { _ in fired += 1 }

        let webView = ScrollForwardingWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            configuration: WKWebViewConfiguration()
        )
        webView.forwardsScrollWheel = false
        webView.zoomBridge = bridge

        webView.scrollWheel(with: makeScrollEvent())
        XCTAssertEqual(fired, 0)
    }
}
