//
//  MermaidView.swift
//  pm_worker
//
//  Mermaid 本地渲染（Task 2.3，E17）：mermaid.min.js 打包进 App bundle，
//  断网可用。渲染方式：bundle 里的 js + 生成的 HTML 落缓存目录，
//  WKWebView loadFileURL + readAccess 收窄到缓存目录。
//

import SwiftUI
import AppKit
import WebKit

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

/// WKWebView 子类：内联模式（内部无可滚内容）把滚轮事件沿响应链上抛，
/// 交给外层 SwiftUI ScrollView——WKWebView 默认在 AppKit 层吞掉 scrollWheel
/// 且不转发，光标悬停在图卡上时外层（.md 预览弹框 / 消息列表）永远滚不动。
/// 滚动模式（放大弹窗）仍走 super，由 HTML 内部滚动消费。
final class ScrollForwardingWebView: WKWebView {
    var forwardsScrollWheel = false

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrollWheel {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
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
        let webView = ScrollForwardingWebView(frame: .zero, configuration: config)
        // 内联模式（scrollable=false）：webview 高度贴合内容、HTML 无可滚区域，
        // 滚轮必须上抛给外层 ScrollView；滚动模式由 HTML 自己滚
        webView.forwardsScrollWheel = !scrollable
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

/// .md 产物预览窗：预览/源码双视图 + 编辑模式（工具条排版 · 撤销/重做 · 保存落盘）。
/// 编辑 = 直接改 markdown 源码（NSTextView 承载），退出编辑即保存；宽幅版面利于长文档阅读。
struct MermaidPreviewSheet: View {
    let title: String
    let fileURL: URL
    @State private var showSource = false
    @State private var markdown: String
    @State private var isEditing = false
    @State private var draft = ""
    @State private var savedText = ""
    @State private var saveError: String?
    @State private var editor = MarkdownEditorController()
    @Environment(\.dismiss) private var dismiss

    /// init 即读盘（原来 onAppear 才读）：首帧直接渲染真实内容，消掉「空文件
    /// 兜底帧闪现 + 弹窗动画中途整页重排」的卡顿观感；13KB 级读取在毫秒档。
    init(title: String, fileURL: URL) {
        self.title = title
        self.fileURL = fileURL
        _markdown = State(initialValue: (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
    }

    /// 草稿相对上次保存的差异
    private var isDirty: Bool { draft != savedText }
    /// 文件读取失败（空内容）不允许进入编辑——避免误存空文件覆盖
    private var canEdit: Bool { !markdown.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header

            DSDivider()

            // 内容区显式隔离动画事务（2026-09-15 崩溃修复）：DSTabs 的选中变化包在
            // withAnimation(spring) 里，若分支交换跟随该事务做过渡动画，源码
            // (NSTextView/NSScrollView)↔预览(MarkdownText) 的多帧过渡会在 AppKit
            // 布局 pass 进行中重入触发 SwiftUI 约束失效（NSHostingView.requestUpdate
            // → setNeedsUpdateConstraints），AppKit 直接抛 NSException 崩溃
            // （-[NSWindow _postWindowNeedsUpdateConstraints]）。内容交换瞬时完成
            // （标签胶囊滑动动画不受影响，它由 header 自己的事务驱动）。
            content
                .transaction { $0.animation = nil }
        }
        // 面板钳在 min–max 之间（ideal 保底尺寸，窗口大于 ideal 时浮卡可长到 max）
        .frame(
            minWidth: 860, idealWidth: 1140, maxWidth: 1280,
            minHeight: 600, idealHeight: 840, maxHeight: 900
        )
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮同动作）
        .onDisappear {
            // 兜底：编辑中直接关窗（非「退出编辑」路径）不丢稿
            if isEditing, isDirty {
                try? draft.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 编辑 / 源码 / 预览三分支内容区（动画事务由 body 统一隔离，见 body 注释）。
    @ViewBuilder
    private var content: some View {
        if isEditing {
            MarkdownEditToolbar(controller: editor)
            DSDivider()
            MarkdownSourceEditor(text: $draft, controller: editor)
        } else if showSource {
            // 源码：NSTextView 惰性排版承载（DSCode 单 Text 对万字符文档同步
            // 排版会卡主线程数秒，见 MarkdownSourceReader 头注释）；卡壳沿用
            // DSCode 视觉（overlayL1 底 + borderL1 发丝线），内部滚动
            MarkdownSourceReader(text: markdown)
                .background(Color.overlayL1, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .strokeBorder(Color.borderL1, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
                .padding(DS.Spacing.s16)
        } else if markdown.isEmpty {
            // 文件读取失败兜底（正常 .md 不会走到）
            VStack {
                Spacer()
                Text("无法读取文件内容")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                Spacer()
            }
        } else {
            // 全文 Markdown 渲染：标题/列表/表格/引用/代码块/行内富文本，
            // ```mermaid 围栏块由 MarkdownText 内联成图卡（复用对话页渲染管线）。
            // longDocument 档：LazyVStack 惰性布局 + prose 合并分块封顶，
            // 首屏即开即显（整篇文档一次性排版会卡主线程，见 MarkdownText 注释）
            DSScroll {
                MarkdownText(markdown, longDocument: true)
                    .padding(DS.Spacing.s16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.s12) {
            Text(title)
                .font(DS.Font.headingSM)
                .foregroundStyle(Color.ink900)
                .lineLimit(1)
            if isEditing {
                if let saveError {
                    Text("保存失败：\(saveError)")
                        .font(DS.Font.bodySM)
                        .foregroundStyle(Color.statusError)
                        .lineLimit(1)
                } else if isDirty {
                    HStack(spacing: DS.Spacing.s4) {
                        Circle().fill(Color.brand600).frame(width: 6, height: 6)
                        Text("未保存")
                            .font(DS.Font.bodySM)
                            .foregroundStyle(Color.ink500)
                    }
                }
            }
            Spacer()
            if isEditing {
                Button("保存") { saveIfNeeded() }
                    .buttonStyle(.ds(.primary, size: .xs))
                    .disabled(!isDirty)
                    .keyboardShortcut("s", modifiers: .command)
                Button("退出编辑") { exitEdit() }
                    .buttonStyle(.ds(.ghost, size: .xs))
                    .keyboardShortcut(.cancelAction)
            } else {
                DSTabs(
                    items: [
                        DSTabItem(false, "预览"),
                        DSTabItem(true, "源码"),
                    ],
                    selection: $showSource
                )
                .frame(width: 140)
                if canEdit {
                    Button {
                        enterEdit()
                    } label: {
                        HStack(spacing: DS.Spacing.s4) {
                            DSIcon(.note, size: 12)
                            Text("编辑")
                        }
                    }
                    .buttonStyle(.ds(.ghost, size: .xs))
                }
                Button("完成") { dismiss() }
                    .buttonStyle(.ds(.primary, size: .xs))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.vertical, DS.Spacing.s10)
    }

    private func enterEdit() {
        draft = markdown
        savedText = markdown
        saveError = nil
        isEditing = true
    }

    private func exitEdit() {
        guard saveIfNeeded() else { return }  // 保存失败留在编辑态
        isEditing = false
    }

    /// 落盘：草稿 ≠ 上次保存才写；成功后刷新预览与基准，失败显错误并保持编辑态。
    @discardableResult
    private func saveIfNeeded() -> Bool {
        // 从编辑器取实时文本（覆盖原生 ⌘Z 等未走 binding 的路径）
        if let live = editor.currentText, live != draft { draft = live }
        guard isEditing, isDirty else { return true }
        do {
            try draft.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = draft
            markdown = draft
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

// MARK: - 文档编辑（工具条排版 + NSTextView 源码编辑器）

/// 编辑工具条：撤销/重做 + Markdown 排版（标题/字重/列表/引用/链接/表格/代码块/分割线）。
/// 排版操作作用于当前选区（选区为空则在光标处插入）；横向可滚（窄窗不截断）。
struct MarkdownEditToolbar: View {
    let controller: MarkdownEditorController

    var body: some View {
        DSScroll(.horizontal) {
            HStack(spacing: DS.Spacing.s2) {
                tool("撤销", "撤销（⌘Z）") { controller.undo() }
                tool("重做", "重做（⇧⌘Z）") { controller.redo() }

                groupDivider

                tool("H1", "一级标题") {
                    controller.apply { MarkdownEditOps.heading(text: $0, range: $1, level: 1) }
                }
                tool("H2", "二级标题") {
                    controller.apply { MarkdownEditOps.heading(text: $0, range: $1, level: 2) }
                }
                tool("H3", "三级标题") {
                    controller.apply { MarkdownEditOps.heading(text: $0, range: $1, level: 3) }
                }

                groupDivider

                styledTool(Text("B").bold(), "加粗 **…**") {
                    controller.apply {
                        MarkdownEditOps.wrapSelection(text: $0, range: $1, prefix: "**", suffix: "**")
                    }
                }
                styledTool(Text("I").italic(), "斜体 *…*") {
                    controller.apply {
                        MarkdownEditOps.wrapSelection(text: $0, range: $1, prefix: "*", suffix: "*")
                    }
                }
                styledTool(Text("S").strikethrough(), "删除线 ~~…~~") {
                    controller.apply {
                        MarkdownEditOps.wrapSelection(text: $0, range: $1, prefix: "~~", suffix: "~~")
                    }
                }
                tool("代码", "行内代码 `…`") {
                    controller.apply {
                        MarkdownEditOps.wrapSelection(text: $0, range: $1, prefix: "`", suffix: "`")
                    }
                }

                groupDivider

                tool("引用", "引用 >") {
                    controller.apply { MarkdownEditOps.toggleLinePrefix(text: $0, range: $1, prefix: "> ") }
                }
                tool("• 列表", "无序列表 -") {
                    controller.apply { MarkdownEditOps.toggleLinePrefix(text: $0, range: $1, prefix: "- ") }
                }
                tool("1. 列表", "有序列表（自动编号）") {
                    controller.apply { MarkdownEditOps.toggleOrderedList(text: $0, range: $1) }
                }

                groupDivider

                tool("链接", "链接 [文本](url)") {
                    controller.apply {
                        MarkdownEditOps.wrapSelection(text: $0, range: $1, prefix: "[", suffix: "](url)")
                    }
                }
                tool("代码块", "``` 围栏代码块") {
                    controller.apply { MarkdownEditOps.codeBlock(text: $0, range: $1) }
                }
                tool("表格", "插入表格骨架") {
                    controller.apply { MarkdownEditOps.table(text: $0, range: $1) }
                }
                tool("分割线", "插入分割线 ---") {
                    controller.apply { MarkdownEditOps.divider(text: $0, range: $1) }
                }
            }
            .padding(.horizontal, DS.Spacing.s8)
        }
        .padding(.horizontal, DS.Spacing.s8)
        .padding(.vertical, DS.Spacing.s6)
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.borderL1)
            .frame(width: 1, height: 14)
            .padding(.horizontal, DS.Spacing.s4)
    }

    private func tool(_ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.bodySM)
        }
        .buttonStyle(.ds(.ghost, size: .xs))
        .help(help)
    }

    private func styledTool(_ label: Text, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label.font(DS.Font.bodySM)
        }
        .buttonStyle(.ds(.ghost, size: .xs))
        .help(help)
    }
}

/// Markdown 排版变换（纯函数）：输入 (全文, UTF-16 选区) → (新全文, 新选区)。
/// 与 AppKit 解耦以便单元测试；NSRange 一律 UTF-16 口径（与 NSTextView.selectedRange 同）。
nonisolated enum MarkdownEditOps {

    /// 选区包裹（toggle）：选区已带前后缀 → 剥离；否则包裹。
    /// 空选区：在光标处插入成对符号，光标落在符号中间。
    static func wrapSelection(
        text: String, range: NSRange, prefix: String, suffix: String
    ) -> (String, NSRange) {
        let ns = text as NSString
        let r = clamp(range, in: ns)
        let sel = ns.substring(with: r)
        if sel.hasPrefix(prefix), sel.hasSuffix(suffix),
           sel.count >= prefix.count + suffix.count {
            let inner = String(sel.dropFirst(prefix.count).dropLast(suffix.count))
            let newText = ns.replacingCharacters(in: r, with: inner)
            return (newText, NSRange(location: r.location, length: (inner as NSString).length))
        }
        let newText = ns.replacingCharacters(in: r, with: prefix + sel + suffix)
        return (
            newText,
            NSRange(
                location: r.location + (prefix as NSString).length,
                length: (sel as NSString).length
            )
        )
    }

    /// 行前缀 toggle（引用 / 无序列表）：选区内所有非空行都带前缀 → 全部移除；否则统一添加。
    /// 空行跳过。
    static func toggleLinePrefix(
        text: String, range: NSRange, prefix: String
    ) -> (String, NSRange) {
        lineOp(text: text, range: range) { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            let removing = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
            return lines.map { line in
                if line.isEmpty { return line }
                if removing {
                    return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
                }
                // 幂等：已带前缀的行不重复加（部分前缀 → 收敛为全部前缀）
                return line.hasPrefix(prefix) ? line : prefix + line
            }
        }
    }

    /// 有序列表 toggle：移除识别 `^\d+\.\s`；添加时按块内顺序重新编号。
    static func toggleOrderedList(text: String, range: NSRange) -> (String, NSRange) {
        lineOp(text: text, range: range) { lines in
            let numberPattern = "^[0-9]+\\.\\s"
            let nonEmpty = lines.filter { !$0.isEmpty }
            let removing = !nonEmpty.isEmpty && nonEmpty.allSatisfy {
                $0.range(of: numberPattern, options: .regularExpression) != nil
            }
            var counter = 0
            return lines.map { line in
                if line.isEmpty { return line }
                let stripped = line.replacingOccurrences(
                    of: numberPattern, with: "", options: .regularExpression
                )
                if removing { return stripped }
                counter += 1
                return "\(counter). \(stripped)"
            }
        }
    }

    /// 标题：选区行统一设为指定级别（先剥既有标题前缀）；
    /// 已全部是指定级别 → 降回普通行（toggle off）。
    static func heading(text: String, range: NSRange, level: Int) -> (String, NSRange) {
        lineOp(text: text, range: range) { lines in
            let marker = String(repeating: "#", count: level) + " "
            let headingPattern = "^#{1,6}\\s+"
            let nonEmpty = lines.filter { !$0.isEmpty }
            let removing = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(marker) }
            return lines.map { line in
                if line.isEmpty { return line }
                let stripped = line.replacingOccurrences(
                    of: headingPattern, with: "", options: .regularExpression
                )
                if removing { return stripped }
                return marker + stripped
            }
        }
    }

    /// 代码块包裹（toggle）：选区被 ``` 围栏整体包裹 → 解除；否则包裹。
    static func codeBlock(text: String, range: NSRange) -> (String, NSRange) {
        wrapSelection(text: text, range: range, prefix: "```\n", suffix: "\n```")
    }

    /// 表格骨架（3 列表头 + 分隔行 + 1 数据行），插入在光标处。
    static func table(text: String, range: NSRange) -> (String, NSRange) {
        insertSnippet(
            text: text, range: range,
            snippet: "\n| 列一 | 列二 | 列三 |\n| --- | --- | --- |\n|  |  |  |\n"
        )
    }

    /// 分割线：前后空行分隔（避免与相邻文本粘连成 setext 标题）。
    static func divider(text: String, range: NSRange) -> (String, NSRange) {
        insertSnippet(text: text, range: range, snippet: "\n\n---\n\n")
    }

    /// 片段插入：替换选区，光标落在片段末尾。
    static func insertSnippet(
        text: String, range: NSRange, snippet: String
    ) -> (String, NSRange) {
        let ns = text as NSString
        let r = clamp(range, in: ns)
        let newText = ns.replacingCharacters(in: r, with: snippet)
        return (newText, NSRange(location: r.location + (snippet as NSString).length, length: 0))
    }

    /// 行级变换骨架：选区扩展到所在行块 → transform → 回写；新选区 = 整个改动行块。
    private static func lineOp(
        text: String, range: NSRange,
        transform: ([String]) -> [String]
    ) -> (String, NSRange) {
        let ns = text as NSString
        let r = clamp(range, in: ns)
        let lineRange = ns.lineRange(for: r)
        var block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        if hadTrailingNewline { block.removeLast() }
        let newLines = transform(block.components(separatedBy: "\n"))
        var newBlock = newLines.joined(separator: "\n")
        if hadTrailingNewline { newBlock += "\n" }
        let newText = ns.replacingCharacters(in: lineRange, with: newBlock)
        return (
            newText,
            NSRange(location: lineRange.location, length: (newBlock as NSString).length)
        )
    }

    /// 越界选区收敛（nil 选区 / 拖尾越界均不崩）
    private static func clamp(_ range: NSRange, in ns: NSString) -> NSRange {
        let length = ns.length
        let loc = max(0, min(range.location, length))
        let end = max(loc, min(range.location + max(range.length, 0), length))
        return NSRange(location: loc, length: end - loc)
    }
}

/// 文档编辑器的命令通道：SwiftUI 按钮侧 → NSTextView 撤销/重做/排版变换。
@MainActor
final class MarkdownEditorController {
    weak var textView: NSTextView?
    /// 文本变化外送（撤销/重做后同步 SwiftUI binding）
    var onTextChange: ((String) -> Void)?

    /// 编辑器实时文本（binding 之外的兜底读取路径）
    var currentText: String? { textView?.string }

    func undo() {
        guard let tv = textView else { return }
        tv.undoManager?.undo()
        onTextChange?(tv.string)
    }

    func redo() {
        guard let tv = textView else { return }
        tv.undoManager?.redo()
        onTextChange?(tv.string)
    }

    /// 排版操作：transform(全文, 当前选区) → (新全文, 新选区)。
    /// 整串注册 undo（shouldChangeText）——一步排版 = 一步撤销，与打字撤销同一撤销栈。
    func apply(_ transform: (String, NSRange) -> (String, NSRange)) {
        guard let tv = textView else { return }
        let (newText, newSel) = transform(tv.string, tv.selectedRange())
        guard newText != tv.string else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        guard tv.shouldChangeText(in: full, replacementString: newText) else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: tv.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: tv.textColor ?? NSColor(Color.ink900),
        ]
        tv.textStorage?.beginEditing()
        tv.textStorage?.setAttributedString(NSAttributedString(string: newText, attributes: attrs))
        tv.textStorage?.endEditing()
        tv.typingAttributes = attrs
        tv.didChangeText()
        tv.setSelectedRange(newSel)
        tv.scrollRangeToVisible(newSel)
    }
}

/// Markdown 源码编辑器（NSTextView）：等宽字体 · 原生撤销（⌘Z/⇧⌘Z）·
/// 中文输入法原生组字 · 透明背景随弹框深浅色。
struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        // Markdown 语法字符必须原样：全关自动替换
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.font = NSFont(name: "JetBrainsMono-Regular", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor(Color.ink900)
        tv.insertionPointColor = NSColor(Color.ink900)
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 16, height: 12)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // 系统粗滚动条统一降噪：覆盖式细条（随滚淡出），与 DSScroll 视觉一致
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false

        context.coordinator.text = $text
        controller.textView = tv
        controller.onTextChange = { context.coordinator.text.wrappedValue = $0 }
        tv.string = text
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        controller.textView = tv
        controller.onTextChange = { context.coordinator.text.wrappedValue = $0 }
        // 外部重置兜底；正常路径文本由 textDidChange 反向同步，不会走到
        if tv.string != text {
            tv.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String> = .constant("")

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

/// 源码只读视图（NSTextView）：大文档秒开的关键——SwiftUI 单 Text 承载整篇
/// markdown（万字符级 CJK）时 CoreText 排版呈超线性（实测 10k 字 ≈ 1.3s 主线程
/// 阻塞，`.fixedSize` 全高求值还会放大排版 pass 数）；NSTextView 惰性排版
/// （只排可视区）+ 内部滚动，任意文档体量即点即显，且保留原生整篇选择/⌘A/复制。
/// 排版与 DSCode 对齐：mono 13 · caption 档行距 · 内衬 16/12；卡壳（overlayL1
/// 底 + borderL1 发丝线）由调用点的 SwiftUI 修饰符承担。
struct MarkdownSourceReader: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.allowsUndo = false
        tv.font = NSFont(name: "JetBrainsMono-Regular", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor(Color.ink900)
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 16, height: 12)
        setText(tv, text)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // 系统粗滚动条统一降噪：覆盖式细条（随滚淡出），与 DSScroll 视觉一致
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { setText(tv, text) }
    }

    /// 带属性整体设置（mono 13 + caption 档行距）——defaultParagraphStyle 对
    /// plain string 赋值不保证生效，排版属性必须进 storage。
    private func setText(_ tv: NSTextView, _ content: String) {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = DS.Typography.leading(for: 13, ratio: DS.Typography.captionRatio)
        tv.textStorage?.setAttributedString(NSAttributedString(string: content, attributes: [
            .font: tv.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(Color.ink900),
            .paragraphStyle: para,
        ]))
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
