//
//  ReleaseBanner.swift
//  pm_worker
//
//  封板版本只读黄条（Task 3.7）：封板版本进入会话 / 项目主页时置顶提示。
//  独立组件：ConversationView 由主 agent 接线（当前版本 status == .released 时展示）；
//  ProjectHomeView 内已直接使用（项目存在封板版本时置顶展示）。
//  视觉还原 Wave 3-B：warning 色系横条（statusWarningSurface1 底 + warning 文字/图标）。
//

import SwiftUI

struct ReleaseBanner: View {
    /// 已封板的版本号（如 v1.0）；nil → 不带版本副标题（一般用于项目级聚合提示）。
    let version: String?
    /// 「查看 release-notes」动作（主 agent 接线：打开 07-reports/release-notes.md 预览）；nil → 不显示按钮。
    var onOpenNotes: (() -> Void)? = nil

    var body: some View {
        DSAlert(
            variant: .warning,
            title: "此版本已封板（目录只读）——回看快照与 release-notes，如需修改请新建版本",
            description: version.map { "封板版本：\($0)" },
            actionTitle: onOpenNotes != nil ? "查看 release-notes" : nil,
            action: onOpenNotes
        )
    }
}
