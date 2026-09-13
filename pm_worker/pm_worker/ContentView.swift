//
//  ContentView.swift
//  pm_worker
//
//  三栏主界面（design.md §9）：左栏三级导航 / 中栏工作区 / 右栏四 Tab 面板。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            middleColumn
                .frame(minWidth: 480)
        } detail: {
            InspectorPanel(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .frame(minWidth: 1080, minHeight: 680)
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch model.selection {
        case .newTask:
            NewTaskView(model: model)
        case .projectHome(let project):
            ProjectHomeView(model: model, projectName: project)
        case .session(let project, let version, let sessionId):
            ConversationView(
                model: model,
                project: project,
                version: version,
                sessionId: sessionId
            )
            .id("\(project)/\(version)/\(sessionId)")  // 切会话即重建视图状态
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
