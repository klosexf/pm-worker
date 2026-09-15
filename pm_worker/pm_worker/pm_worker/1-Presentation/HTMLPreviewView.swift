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

/// 包装 WKWebView（NSViewRepresentable）。
struct HTMLPreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 单文件 HTML：JS 必开（原型可交互），本地文件读权限收窄到所在目录
        // （javaScriptEnabled 已弃用，改用 defaultWebpagePreferences）
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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
