//
//  MermaidView.swift
//  pm_worker
//
//  Mermaid 本地渲染（Task 2.3，E17）：mermaid.min.js 打包进 App bundle，
//  断网可用。渲染方式：bundle 里的 js + 生成的 HTML 落缓存目录，
//  WKWebView loadFileURL + readAccess 收窄到缓存目录。
//

import SwiftUI
import WebKit

/// 从 .md 文件提取 mermaid 围栏块。
nonisolated enum MermaidExtractor {
    struct Diagram: Identifiable, Equatable {
        var title: String   // 上方最近的标题行（# xx），缺省「图 N」
        var source: String
        var id: String { title + source }
    }

    static func diagrams(in markdown: String) -> [Diagram] {
        let pattern = "(?s)```mermaid[ \\t]*\\n(.*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = markdown as NSString
        let matches = regex.matches(
            in: markdown, range: NSRange(location: 0, length: ns.length)
        )
        var results: [Diagram] = []
        for (index, match) in matches.enumerated() where match.numberOfRanges >= 2 {
            let source = ns.substring(with: match.range(at: 1))
            // 标题：围栏块之前最近的 # 行
            let before = ns.substring(with: NSRange(location: 0, length: match.range.location))
            let title = before
                .split(separator: "\n", omittingEmptySubsequences: true)
                .reversed()
                .drop(while: { !$0.hasPrefix("#") })
                .first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            results.append(
                Diagram(title: title ?? "图 \(index + 1)", source: String(source))
            )
        }
        return results
    }
}

/// 单个 Mermaid 图渲染（WKWebView + 本地 mermaid.min.js）。
/// 外层 View 读 colorScheme → dark 传入 representable：深色走 mermaid dark 主题。
/// 高度自适应：mermaid 渲染完成后由 JS 回报内容高度，容器贴合图形。
/// zoom：显示缩放（按 viewBox 矢量放大，保持清晰），放大弹窗用 1.5。
/// scrollable：true → webview 填满容器、由 HTML 内部滚动（放大弹窗）；
/// false → webview 贴合内容高度（对话内联，滚动交给外层消息列表）。
struct MermaidView: View {
    let source: String
    var zoom: CGFloat = 1
    var scrollable: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 180

    var body: some View {
        if scrollable {
            // 内部滚动模式：不设内容高度 frame，填满给定容器即可
            MermaidWebView(
                source: source,
                dark: colorScheme == .dark,
                zoom: zoom,
                scrollable: true,
                onHeight: { contentHeight = $0 }
            )
        } else {
            MermaidWebView(
                source: source,
                dark: colorScheme == .dark,
                zoom: zoom,
                onHeight: { contentHeight = $0 }
            )
            .frame(height: max(120, contentHeight))
        }
    }
}

/// WKWebView 承载（NSViewRepresentable）：源码或外观变化时重渲染。
struct MermaidWebView: NSViewRepresentable {
    let source: String
    var dark: Bool = false
    /// 渲染后按 viewBox 放大倍率重设 svg 尺寸（矢量缩放不失真）。
    var zoom: CGFloat = 1
    /// true → HTML body overflow:auto，滚轮在 webview 内部滚动（放大弹窗）。
    var scrollable: Bool = false
    /// mermaid 渲染完成后 JS 回报内容高度（px）。
    var onHeight: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // mermaid.min.js 渲染需 JS（javaScriptEnabled 已弃用，改用 defaultWebpagePreferences）
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 渲染完成 → 高度回报（对话页内联自适应布局依赖）
        config.userContentController.add(context.coordinator, name: "mermaidHeight")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")  // 透明背景随模式
        context.coordinator.webView = webView
        context.coordinator.onHeight = onHeight
        context.coordinator.render(
            source: source, dark: dark, zoom: zoom, scrollable: scrollable
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.render(
            source: source, dark: dark, zoom: zoom, scrollable: scrollable
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onHeight: ((CGFloat) -> Void)?
        private var renderedSource: String = ""
        private var renderedDark: Bool = false
        private var renderedZoom: CGFloat = 1
        private var renderedScrollable: Bool = false

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "mermaidHeight",
                  let height = message.body as? NSNumber else { return }
            onHeight?(max(CGFloat(height.doubleValue), 40))
        }

        /// 渲染：mermaid.min.js + 图源写入缓存目录，loadFileURL 加载。
        /// source / dark / zoom / scrollable 任一变化都触发整页重渲染。
        func render(source: String, dark: Bool, zoom: CGFloat, scrollable: Bool) {
            guard source != renderedSource || dark != renderedDark
                    || zoom != renderedZoom || scrollable != renderedScrollable,
                  let webView else { return }
            guard let htmlURL = Self.writeRenderHTML(
                source: source, dark: dark, zoom: zoom, scrollable: scrollable
            ) else {
                return
            }
            renderedSource = source
            renderedDark = dark
            renderedZoom = zoom
            renderedScrollable = scrollable
            webView.loadFileURL(
                htmlURL,
                allowingReadAccessTo: htmlURL.deletingLastPathComponent()
            )
        }

        /// 缓存目录：~/Library/Caches/pm-worker/mermaid/（bundle 里的 js 拷贝到此处）。
        static var cacheDir: URL {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("pm-worker/mermaid", isDirectory: true)
            return dir
        }

        /// 确保 mermaid.min.js 在缓存目录（bundle → 缓存，一次拷贝）。
        static func ensureMermaidJS() -> URL? {
            let fm = FileManager.default
            let dest = cacheDir.appendingPathComponent("mermaid.min.js")
            if fm.fileExists(atPath: dest.path) { return dest }
            guard let bundled = Bundle.main.url(
                forResource: "mermaid.min", withExtension: "js"
            ) else { return nil }
            do {
                try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try fm.copyItem(at: bundled, to: dest)
                return dest
            } catch {
                return nil
            }
        }

        static func writeRenderHTML(
            source: String, dark: Bool, zoom: CGFloat = 1, scrollable: Bool = false
        ) -> URL? {
            guard ensureMermaidJS() != nil else { return nil }
            let escaped = source
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            let themeAttr = dark ? "dark" : "light"
            // scroll 模式（放大弹窗）：body 内部滚动——WKWebView 会消费滚轮事件且不
            // 转发外层，SwiftUI 外层 ScrollView 永远滚不动，必须让 HTML 自己滚
            let bodyClass = scrollable ? "scroll" : ""
            let bodyCSS = scrollable
                ? "body.scroll { width: 100%; height: 100%; overflow: auto; padding: 16px; box-sizing: border-box; }"
                : ""
            // margin 0：外边距由 SwiftUI 容器控制；渲染完成（含失败）回报内容高度
            let html = """
            <!DOCTYPE html>
            <html data-theme="\(themeAttr)">
            <head>
            <meta charset="utf-8">
            <style>
              body { margin: 0; background: transparent; font-family: -apple-system, "PingFang SC", sans-serif; }
              /* 居中用 margin auto（flex center 对超宽子元素会产生不可滚动的左侧溢出） */
              .mermaid svg { display: block; margin: 0 auto; }
              \(bodyCSS)
              .error { color: #d12; font-size: 12px; padding: 8px; }
              html[data-theme="dark"] .error { color: #ff8a7d; }
            </style>
            <script src="mermaid.min.js"></script>
            <script>
              const ZOOM = \(zoom);
              function postHeight() {
                try {
                  window.webkit.messageHandlers.mermaidHeight.postMessage(
                    document.body.scrollHeight
                  );
                } catch (e) {}
              }
              // 放大查看：按 viewBox 重设 svg 尺寸——矢量缩放，分辨率不失真
              function scaleSVG() {
                if (ZOOM === 1) return;
                var svg = document.querySelector('.mermaid svg');
                if (!svg) return;
                var vb = svg.viewBox.baseVal;
                if (vb && vb.width > 0 && vb.height > 0) {
                  svg.setAttribute('width', vb.width * ZOOM);
                  svg.setAttribute('height', vb.height * ZOOM);
                  svg.style.maxWidth = 'none';
                }
              }
              mermaid.initialize({
                startOnLoad: false,
                theme: document.documentElement.dataset.theme === "dark" ? "dark" : "default",
                securityLevel: "strict"
              });
              function renderNow() {
                mermaid.run()
                  .then(function () { scaleSVG(); postHeight(); })
                  .catch(postHeight);
              }
              // 本脚本在 <head> 中先于 <body> 解析执行——立即 run() 找不到任何
              // .mermaid 元素（图卡显示原始源码）→ 必须等 DOM 就绪再渲染
              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", renderNow);
              } else {
                renderNow();
              }
              window.onerror = function (msg) {
                document.body.innerHTML =
                  '<div class="error">渲染失败：' + msg + '</div>';
                postHeight();
              };
            </script>
            </head>
            <body class="\(bodyClass)">
            <pre class="mermaid">
            \(escaped)
            </pre>
            </body>
            </html>
            """
            let url = cacheDir.appendingPathComponent("render-\(UUID().uuidString).html")
            do {
                try FileManager.default.createDirectory(
                    at: cacheDir, withIntermediateDirectories: true
                )
                try Data(html.utf8).write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
    }
}

/// .md 产物预览窗：Mermaid 图序列渲染 + 源码/预览双视图。
struct MermaidPreviewSheet: View {
    let title: String
    let fileURL: URL
    @State private var showSource = false
    @State private var markdown: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s12) {
                Text(title)
                    .font(DS.Font.headingSM)
                    .foregroundStyle(Color.ink900)
                Spacer()
                DSTabs(
                    items: [
                        DSTabItem(false, "预览"),
                        DSTabItem(true, "源码"),
                    ],
                    selection: $showSource
                )
                .frame(width: 140)
                Button("在浏览器打开") { NSWorkspace.shared.open(fileURL) }
                    .buttonStyle(.ds(.ghost, size: .xs))
                Button("完成") { dismiss() }
                    .buttonStyle(.ds(.primary, size: .xs))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Spacing.s16)
            .padding(.vertical, DS.Spacing.s10)

            DSDivider()

            let diagrams = MermaidExtractor.diagrams(in: markdown)
            if showSource {
                ScrollView {
                    DSCode(text: markdown)
                        .padding(DS.Spacing.s16)
                }
            } else if diagrams.isEmpty {
                VStack {
                    Spacer()
                    Text("未找到 mermaid 图（该文件可能是纯文本表格）")
                        .font(DS.Font.bodySM)
                        .foregroundStyle(Color.ink500)
                    ScrollView {
                        DSCode(text: markdown)
                            .padding(DS.Spacing.s16)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.s16) {
                        ForEach(diagrams) { diagram in
                            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                                Text(diagram.title)
                                    .font(DS.Font.bodyMDStrong)
                                    .foregroundStyle(Color.ink900)
                                MermaidView(source: diagram.source)
                                    .padding(DS.Spacing.s12)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Radius.lg)
                                            .fill(Color.overlayL1)
                                    )
                            }
                        }
                    }
                    .padding(DS.Spacing.s16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            markdown = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }
}

// MARK: - 内联图卡（工具条：源代码切换 / 放大弹窗）

/// 放大倍率（≥150%）：按 viewBox 重设 svg 尺寸，矢量缩放不失真。
private let mermaidZoomFactor: CGFloat = 1.5

/// 图卡工具条：查看源代码（与图表视图互切）/ 放大图表（弹窗）。
struct MermaidFigureToolbar: View {
    @Binding var showSource: Bool
    var onZoom: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s2) {
            Button {
                showSource.toggle()
            } label: {
                HStack(spacing: DS.Spacing.s4) {
                    DSIcon(showSource ? .layers : .code, size: 12)
                    Text(showSource ? "返回图表" : "查看源代码")
                }
            }
            .buttonStyle(.ds(.ghost, size: .xs))

            Button(action: onZoom) {
                HStack(spacing: DS.Spacing.s4) {
                    DSIcon(.expand, size: 12)
                    Text("放大图表")
                }
            }
            .buttonStyle(.ds(.ghost, size: .xs))
        }
    }
}

/// 内联 mermaid 图卡（对话页直接渲染，无需点击预览）。
/// 头部：标题（nil → "mermaid" 语言标签）+ 源码态复制钮 + 工具条；
/// 图表与源码互切；放大弹窗 1.5× 矢量呈现。
/// 供两处使用：MessageBubble 内联产物图（带标题）、MarkdownText ```mermaid 围栏块。
struct MermaidFigureCard: View {
    let source: String
    var title: String? = nil
    var icon: DSIcon.Name? = nil
    @State private var showSource = false
    @State private var showZoom = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.s8) {
                if let title {
                    HStack(spacing: DS.Spacing.s6) {
                        if let icon {
                            DSIcon(icon, size: 13)
                                .foregroundStyle(Color.ink500)
                        }
                        Text(title)
                            .font(DS.Font.bodyMDStrong)
                            .foregroundStyle(Color.ink900)
                    }
                } else {
                    Text("mermaid")
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink500)
                }
                Spacer(minLength: DS.Spacing.s8)
                if showSource {
                    copyButton
                }
                MermaidFigureToolbar(showSource: $showSource, onZoom: { showZoom = true })
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)

            DSDivider()

            Group {
                if showSource {
                    // 源码视图：mono 14 可选中（不内滚，折行同代码块纪律）
                    Text(source)
                        .font(DS.Font.monoLG)
                        .dsCaptionType(size: 14)
                        .foregroundStyle(Color.ink900)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(DS.Spacing.s12)
                } else {
                    MermaidView(source: source)
                        .padding(DS.Spacing.s12)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.surfaceTertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        .sheet(isPresented: $showZoom) {
            MermaidZoomSheet(title: title ?? "mermaid 图表", source: source)
        }
    }

    private var copyButton: some View {
        Button {
            copySource()
        } label: {
            Group {
                if copied {
                    DSIcon(.check, size: 13)
                        .foregroundStyle(Color.statusSuccess)
                } else {
                    DSIcon(.copy, size: 13)
                        .foregroundStyle(Color.ink500)
                }
            }
        }
        .buttonStyle(.plain)
        .help("复制源代码")
    }

    private func copySource() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
        guard !copied else { return }
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// 放大查看弹窗：1.5× 矢量放大（横向/纵向可滚动）；
/// 点空白遮罩 / 关闭按钮 / Esc 均可关闭。
struct MermaidZoomSheet: View {
    let title: String
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // 空白遮罩：点击关闭
            Color.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.s12) {
                    Text(title)
                        .font(DS.Font.headingSM)
                        .foregroundStyle(Color.ink900)
                    Spacer()
                    Button("关闭") { dismiss() }
                        .buttonStyle(.ds(.primary, size: .xs))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, DS.Spacing.s16)
                .padding(.vertical, DS.Spacing.s10)

                DSDivider()

                // 滚动由 webview 内部 HTML 承担（WKWebView 消费滚轮事件且不转发
                // 外层 ScrollView，外层永远滚不动）——这里只给有界容器
                MermaidView(source: source, zoom: mermaidZoomFactor, scrollable: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.big)
                    .fill(Color.surfaceBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.big)
                    .strokeBorder(Color.overlayBorder, lineWidth: 1)
            )
            .dsShadow(.overlay)  // 投影只属于模态
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.big))
            .contentShape(Rectangle())
            .onTapGesture {}  // 卡片内点击不冒泡到遮罩
            .padding(DS.Spacing.s16)
        }
        .frame(minWidth: 1020, minHeight: 700)
        .presentationBackground(.clear)
    }
}
