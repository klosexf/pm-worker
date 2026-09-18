//
//  HTMLPreviewView.swift
//  pm_worker
//
//  WKWebView 预搭（Task 1.7，E21）：本地单文件 HTML 加载渲染
//  （依赖全内联，断网无白屏）+「在浏览器打开」兜底。
//  M2 原型 Agent 复用此组件。
//

import SwiftUI
import WebKit

/// 原型/HTML 预览（外壳）：WKWebView 原生滚动条隐藏（macOS 26 玻璃样式
/// 无法 CSS 定制，且 26.0 不支持 scrollbar-color），由 JS 滚动进度回报
/// 驱动外挂 DS 细胶囊——与消息流 DSScroll 观感一致。
struct HTMLPreviewView: View {
    let fileURL: URL
    @State private var vScroll = DSScrollSnapshot.hidden
    @State private var hScroll = DSScrollSnapshot.hidden

    var body: some View {
        HTMLPreviewNSView(
            fileURL: fileURL,
            onScroll: { vp, vf, hp, hf in
                vScroll = DSScrollSnapshot(progress: vp, fraction: vf)
                hScroll = DSScrollSnapshot(progress: hp, fraction: hf)
            }
        )
        .dsExternalScrollbar(axis: .vertical, snapshot: $vScroll)
        .dsExternalScrollbar(axis: .horizontal, snapshot: $hScroll)
    }
}

/// WKWebView 承载（NSViewRepresentable）。
private struct HTMLPreviewNSView: NSViewRepresentable {
    let fileURL: URL
    var onScroll: ((CGFloat, CGFloat, CGFloat, CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onScroll: ((CGFloat, CGFloat, CGFloat, CGFloat) -> Void)?

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "pmScroll",
                  let body = message.body as? [String: NSNumber],
                  let vp = body["vProgress"], let vf = body["vFraction"],
                  let hp = body["hProgress"], let hf = body["hFraction"] else { return }
            onScroll?(
                CGFloat(vp.doubleValue), CGFloat(vf.doubleValue),
                CGFloat(hp.doubleValue), CGFloat(hf.doubleValue)
            )
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 单文件 HTML：JS 必开（原型可交互），本地文件读权限收窄到所在目录
        // （javaScriptEnabled 已弃用，改用 defaultWebpagePreferences）
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 滚动条降噪（2026-09-17）：隐藏原生滚动条（scrollbar-width: none，
        // Safari 18.2+ 支持；::-webkit-scrollbar 全系不支持、scrollbar-color
        // 要 26.2+），原生侧外挂 DS 细胶囊替代
        let scrollbarStyle = WKUserScript(
            source: """
            (function () {
              var s = document.createElement('style');
              s.textContent = 'html{scrollbar-width:none}';
              document.head.appendChild(s);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(scrollbarStyle)
        // 文档滚动进度回报（驱动外挂胶囊）
        config.userContentController.add(context.coordinator, name: "pmScroll")
        config.userContentController.addUserScript(
            WKUserScript(
                source: webViewScrollReporterJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.onScroll = onScroll
        load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onScroll = onScroll
        // 同一 URL 不重复加载
        if webView.url == nil { load(webView) }
    }

    private func load(_ webView: WKWebView) {
        // loadFileURL + readAccess 收窄到文件所在目录：沙箱外本地文件权限正确
        webView.loadFileURL(
            fileURL,
            allowingReadAccessTo: fileURL.deletingLastPathComponent()
        )
    }
}

/// 预览容器（标题栏 + 「在浏览器打开」兜底入口）。
struct HTMLPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let fileURL: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Label {
                        Text("在浏览器打开")
                    } icon: {
                        DSIcon(.arrowUpRight, size: 14)
                    }
                    .font(.caption)
                }
                .help("兜底：用系统默认浏览器打开该 HTML 文件")
                Button {
                    dismiss()
                } label: {
                    DSIcon(.close, size: 16)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            HTMLPreviewView(fileURL: fileURL)
                .ignoresSafeArea()
        }
        // 面板钳在 min–max 之间（ideal 保底尺寸，窗口大于 ideal 时浮卡可长到 max）
        .frame(
            minWidth: 860, idealWidth: 1080, maxWidth: 1280,
            minHeight: 600, idealHeight: 780, maxHeight: 880
        )
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮同动作）
    }
}
