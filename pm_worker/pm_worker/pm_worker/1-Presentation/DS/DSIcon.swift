//
//  DSIcon.swift
//  pm_worker
//
//  TraeWork 图标体系（图标统一 Wave · SF Symbols 桥接）：
//  · 统一入口 = DSIcon(.name, size:)，调用点仍禁止直接写 Image(systemName:)
//  · 渲染优先走 SF Symbols（系统字体管线：可变字重 / 光学尺寸 / 深浅色自适应，
//    hierarchical / palette 渲染模式可用）；颜色语义仍为 currentColor，由 foregroundStyle 决定
//  · 个别品牌字符（agent 机器人头像、markdown 文件徽标）保留自绘 SVG path 兜底
//    （16×16 viewBox · M/L/H/V/C/Z 六命令解析 · currentColor 单色 · 禁用 emoji）
//

import SwiftUI

// MARK: - SVG path 解析（M/L/H/V/C/Z）— 仅自绘兜底图标使用

/// 解析 SVG path `d` 属性。自绘兜底仅使用这六种命令（无 S/Q/T/A），含相对坐标与隐式重复。
nonisolated enum SVGPathParser {

    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        let n = chars.count
        var i = 0
        var command: Character = " "
        var cx: CGFloat = 0, cy: CGFloat = 0
        var sx: CGFloat = 0, sy: CGFloat = 0

        func skipSeparators() {
            while i < n, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
                i += 1
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            while i < n {
                let c = chars[i]
                if c.isNumber || c == "." {
                    s.append(c); i += 1
                } else if c == "-" || c == "+" {
                    if s.isEmpty {
                        s.append(c); i += 1
                    } else {
                        break   // 隐式分隔：新数字开始（如 "10.2249-6.22429"）
                    }
                } else {
                    break
                }
            }
            guard !s.isEmpty else { return nil }
            return CGFloat(Double(s) ?? 0)
        }

        while i < n {
            skipSeparators()
            guard i < n else { break }
            let c = chars[i]
            if c.isLetter {
                command = c
                i += 1
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    cx = sx; cy = sy
                    continue
                }
            } else {
                // 隐式重复：M→L、m→l，其余沿用上一命令
                command = command == "M" ? "L" : (command == "m" ? "l" : command)
            }
            guard command.isLetter else { i += 1; continue }

            switch command {
            case "M":
                guard let x = readNumber(), let y = readNumber() else { return path }
                path.move(to: CGPoint(x: x, y: y)); cx = x; cy = y; sx = x; sy = y
            case "m":
                guard let dx = readNumber(), let dy = readNumber() else { return path }
                cx += dx; cy += dy
                path.move(to: CGPoint(x: cx, y: cy)); sx = cx; sy = cy
            case "L":
                guard let x = readNumber(), let y = readNumber() else { return path }
                path.addLine(to: CGPoint(x: x, y: y)); cx = x; cy = y
            case "l":
                guard let dx = readNumber(), let dy = readNumber() else { return path }
                cx += dx; cy += dy
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "H":
                guard let x = readNumber() else { return path }
                path.addLine(to: CGPoint(x: x, y: cy)); cx = x
            case "h":
                guard let dx = readNumber() else { return path }
                cx += dx
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "V":
                guard let y = readNumber() else { return path }
                path.addLine(to: CGPoint(x: cx, y: y)); cy = y
            case "v":
                guard let dy = readNumber() else { return path }
                cy += dy
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "C":
                guard let c1x = readNumber(), let c1y = readNumber(),
                      let c2x = readNumber(), let c2y = readNumber(),
                      let x = readNumber(), let y = readNumber() else { return path }
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: c1x, y: c1y),
                              control2: CGPoint(x: c2x, y: c2y))
                cx = x; cy = y
            case "c":
                guard let c1x = readNumber(), let c1y = readNumber(),
                      let c2x = readNumber(), let c2y = readNumber(),
                      let dx = readNumber(), let dy = readNumber() else { return path }
                path.addCurve(to: CGPoint(x: cx + dx, y: cy + dy),
                              control1: CGPoint(x: cx + c1x, y: cy + c1y),
                              control2: CGPoint(x: cx + c2x, y: cy + c2y))
                cx += dx; cy += dy
            default:
                i += 1
            }
        }
        return path
    }
}

// MARK: - 图标定义与缓存

/// 自绘兜底的单个图标定义：若干 path 段（fill / stroke）。
struct DSIconDef {
    enum Segment {
        case fill(d: String, eo: Bool)
        case stroke(d: String, width: CGFloat, round: Bool)
    }

    let segments: [Segment]
}

/// d 字符串 → Path 的全局缓存（视图 body 重算不重复解析）。
nonisolated final class DSIconPathCache: @unchecked Sendable {
    static let shared = DSIconPathCache()
    private let lock = NSLock()
    private var storage: [String: Path] = [:]

    func path(for d: String) -> Path {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[d] { return cached }
        let parsed = SVGPathParser.parse(d)
        storage[d] = parsed
        return parsed
    }
}

// MARK: - DSIcon 视图

/// TraeWork 单色图标。颜色由 foregroundStyle 决定（currentColor 语义）。
///
///     DSIcon(.document, size: 15)
///     DSIcon(.search, size: 14).foregroundStyle(Color.ink500)
///
struct DSIcon: View {
    let name: Name
    var size: CGFloat = 16

    init(_ name: Name, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Group {
            if let symbol = name.symbol {
                Image(systemName: symbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let def = name.def {
                ZStack {
                    ForEach(Array(def.segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment)
                    }
                }
            }
        }
        .rotationEffect(name.rotation)
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func segmentView(_ segment: DSIconDef.Segment) -> some View {
        let scale = size / 16
        switch segment {
        case .fill(let d, let eo):
            DSIconShape(path: DSIconPathCache.shared.path(for: d))
                .fill(style: eo ? FillStyle(eoFill: true) : FillStyle())
                .frame(width: size, height: size)
        case .stroke(let d, let w, let round):
            DSIconShape(path: DSIconPathCache.shared.path(for: d))
                .stroke(style: StrokeStyle(
                    lineWidth: max(w * scale, 0.5),
                    lineCap: round ? .round : .butt,
                    lineJoin: .round
                ))
                .frame(width: size, height: size)
        }
    }
}

/// 16×16 坐标系 path → 任意 rect 的等比缩放映射（绕 8,8 中心）。
private struct DSIconShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 16
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -8, y: -8)
        return path.applying(transform)
    }
}

// MARK: - 图标名（SF Symbols 映射 + 少量自绘兜底）

extension DSIcon {
    struct Name {
        /// SF Symbol 名（优先渲染；nil 走自绘 path 兜底）
        let symbol: String?
        /// 自绘 SVG path 兜底（仅品牌字符）
        let def: DSIconDef?
        /// 整体旋转（如垂直省略号 = ellipsis 转 90°）
        var rotation: Angle = .zero

        init(symbol: String, rotation: Angle = .zero) {
            self.symbol = symbol
            self.def = nil
            self.rotation = rotation
        }

        init(_ segments: [DSIconDef.Segment]) {
            self.symbol = nil
            self.def = DSIconDef(segments: segments)
            self.rotation = .zero
        }
    }
}

extension DSIcon.Name {

    // MARK: SF Symbols 桥接（语义对齐原自绘/原型图标）

    static let arrowLeft = DSIcon.Name(symbol: "arrow.left")
    static let barList = DSIcon.Name(symbol: "line.3.horizontal")
    static let browser = DSIcon.Name(symbol: "safari")
    static let close = DSIcon.Name(symbol: "xmark")
    static let collapseTriangle = DSIcon.Name(symbol: "arrowtriangle.right.fill")
    static let delete = DSIcon.Name(symbol: "trash")
    static let down = DSIcon.Name(symbol: "chevron.down")
    static let expand = DSIcon.Name(symbol: "arrow.up.left.and.arrow.down.right")
    static let folder = DSIcon.Name(symbol: "folder")
    static let link = DSIcon.Name(symbol: "link")
    static let lock = DSIcon.Name(symbol: "lock")
    static let notification = DSIcon.Name(symbol: "bell.fill")
    static let panelRight = DSIcon.Name(symbol: "sidebar.right")
    static let plus = DSIcon.Name(symbol: "plus")
    static let qps = DSIcon.Name(symbol: "chart.bar.fill")
    static let refresh = DSIcon.Name(symbol: "arrow.clockwise")
    static let search = DSIcon.Name(symbol: "magnifyingglass")
    static let send = DSIcon.Name(symbol: "paperplane.fill")
    static let split = DSIcon.Name(symbol: "rectangle.split.2x1")
    static let stop = DSIcon.Name(symbol: "stop.fill")
    static let star = DSIcon.Name(symbol: "star.fill")
    static let switchIcon = DSIcon.Name(symbol: "arrow.left.arrow.right")
    static let table = DSIcon.Name(symbol: "tablecells")
    static let unlike = DSIcon.Name(symbol: "hand.thumbsdown")
    static let aiStars = DSIcon.Name(symbol: "sparkles")
    static let automation = DSIcon.Name(symbol: "timer")
    static let chat = DSIcon.Name(symbol: "bubble.left")
    static let check = DSIcon.Name(symbol: "checkmark")
    static let clock = DSIcon.Name(symbol: "clock")
    static let code = DSIcon.Name(symbol: "chevron.left.forwardslash.chevron.right")
    static let designPalette = DSIcon.Name(symbol: "paintpalette")
    static let doc = DSIcon.Name(symbol: "doc.text")
    static let document = DSIcon.Name(symbol: "document")
    static let download = DSIcon.Name(symbol: "arrow.down.circle")
    static let fileUpload = DSIcon.Name(symbol: "square.and.arrow.up")
    static let glasses = DSIcon.Name(symbol: "glasses")
    static let warningFill = DSIcon.Name(symbol: "exclamationmark.circle.fill")
    static let importIcon = DSIcon.Name(symbol: "square.and.arrow.down")
    static let lightBulb = DSIcon.Name(symbol: "lightbulb")
    static let mem = DSIcon.Name(symbol: "brain")
    static let play = DSIcon.Name(symbol: "play.fill")
    static let skull = DSIcon.Name(symbol: "skull")
    static let question = DSIcon.Name(symbol: "questionmark")
    static let newTask = DSIcon.Name(symbol: "doc.badge.plus")
    static let puzzle = DSIcon.Name(symbol: "puzzlepiece.fill")
    static let books = DSIcon.Name(symbol: "books.vertical")
    static let connector = DSIcon.Name(symbol: "cableplug")
    static let home = DSIcon.Name(symbol: "house.fill")
    static let layers = DSIcon.Name(symbol: "square.3.layers.3d")
    static let bookmark = DSIcon.Name(symbol: "bookmark.fill")
    static let bolt = DSIcon.Name(symbol: "bolt.fill")
    static let note = DSIcon.Name(symbol: "note.text")
    static let thumbsUp = DSIcon.Name(symbol: "hand.thumbsup")
    static let flask = DSIcon.Name(symbol: "testtube.2")
    static let circleCheck = DSIcon.Name(symbol: "checkmark.circle")
    static let circleMinus = DSIcon.Name(symbol: "minus.circle")
    static let circleX = DSIcon.Name(symbol: "xmark.circle")
    static let dot = DSIcon.Name(symbol: "circle.fill")
    static let more = DSIcon.Name(symbol: "ellipsis")
    /// 垂直省略号（档案树项目/版本行「更多操作」入口 · ⋮）
    static let moreVertical = DSIcon.Name(symbol: "ellipsis", rotation: .degrees(90))
    static let pencil = DSIcon.Name(symbol: "pencil")
    static let arrowSwap = DSIcon.Name(symbol: "arrow.left.arrow.right")
    static let arrowUp = DSIcon.Name(symbol: "arrow.up")
    static let arrowRight = DSIcon.Name(symbol: "arrow.right")
    static let arrowUpRight = DSIcon.Name(symbol: "arrow.up.right")
    static let gear = DSIcon.Name(symbol: "gearshape")
    static let chevronUp = DSIcon.Name(symbol: "chevron.up")
    static let chevronRight = DSIcon.Name(symbol: "chevron.right")
    static let copy = DSIcon.Name(symbol: "doc.on.doc")
    /// 图表放大弹窗工具条：缩小 / 放大
    static let zoomOut = DSIcon.Name(symbol: "minus.magnifyingglass")
    static let zoomIn = DSIcon.Name(symbol: "plus.magnifyingglass")

    // MARK: 自绘兜底（品牌字符）

    /// agent 机器人头像（品牌字符：设置/侧栏 Agent 身份标识）
    static let agent = DSIcon.Name([
        .fill(d: #"M13.0417 5.33301C13.0416 4.57376 12.4261 3.95801 11.6667 3.95801H4.33374C3.57446 3.95801 2.95892 4.57377 2.95874 5.33301V10.667C2.95892 11.4263 3.57445 12.042 4.33374 12.042H11.6667C12.4261 12.042 13.0416 11.4263 13.0417 10.667V5.33301ZM9.33374 9.04199C9.67877 9.04217 9.95874 9.32192 9.95874 9.66699C9.95856 10.0119 9.67866 10.2918 9.33374 10.292H6.66675C6.32168 10.292 6.04192 10.012 6.04175 9.66699C6.04175 9.32181 6.32157 9.04199 6.66675 9.04199H9.33374ZM5.66675 5.70801C6.19602 5.70801 6.62476 6.13772 6.62476 6.66699C6.62458 7.19605 6.19594 7.625 5.66675 7.625C5.17054 7.625 4.76271 7.24783 4.71362 6.76465L4.70874 6.66699L4.71362 6.56836C4.76286 6.08528 5.17068 5.70801 5.66675 5.70801ZM10.4314 5.71289C10.9146 5.76195 11.2917 6.17076 11.2917 6.66699C11.2916 7.19598 10.8627 7.62482 10.3337 7.625C9.83756 7.625 9.4287 7.24789 9.37964 6.76465L9.37476 6.66699L9.37964 6.56836C9.42885 6.08522 9.8377 5.70801 10.3337 5.70801L10.4314 5.71289ZM14.2917 5.53711C14.689 5.7574 14.9587 6.18054 14.9587 6.66699C14.9586 7.15327 14.6889 7.57564 14.2917 7.7959V10.667C14.2916 12.1166 13.1164 13.292 11.6667 13.292H4.33374C2.88411 13.292 1.70892 12.1166 1.70874 10.667V7.79688C1.31126 7.57672 1.04187 7.15354 1.04175 6.66699C1.04175 6.18027 1.31109 5.75632 1.70874 5.53613V5.33301C1.70892 3.88341 2.8841 2.70801 4.33374 2.70801H7.37476V2C7.37476 1.65493 7.65473 1.37518 7.99976 1.375C8.34493 1.375 8.62476 1.65482 8.62476 2V2.70801H11.6667C13.1164 2.70801 14.2916 3.88342 14.2917 5.33301V5.53711Z"#, eo: false),
    ])

    /// Markdown 文件徽标（品牌字符：圆角描边框 + M + 下箭头 · 文件树 .md 类型标）
    static let markdown = DSIcon.Name([
        .stroke(d: #"M3 3.6 H13 C14.05 3.6 14.9 4.45 14.9 5.5 V10.5 C14.9 11.55 14.05 12.4 13 12.4 H3 C1.95 12.4 1.1 11.55 1.1 10.5 V5.5 C1.1 4.45 1.95 3.6 3 3.6 Z"#, width: 1.2, round: true),
        .stroke(d: #"M4 10.4 V5.6 L6.4 8.3 L8.8 5.6 V10.4"#, width: 1.2, round: true),
        .fill(d: #"M10.75 5.6 H11.95 V8.7 H13.35 L11.35 10.9 L9.35 8.7 H10.75 Z"#, eo: false),
    ])
}
