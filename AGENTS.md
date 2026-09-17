# AGENTS.md — PM Copilot (pm_worker)

面向 AI 编码代理的项目约定。动手前先读完本文件，可避免本仓库已付出过学费的所有坑。

## 项目是什么

Local-first AI PM copilot（macOS 原生 App，SwiftUI）。四阶段门控流水线：澄清 → 结构 → 原型 → PRD，人类确认门控推进；文件系统是事实源，SQLite 只是可重建索引；BYOK、零遥测。通过 stdio MCP 对外暴露 6 个工具。

产品/架构文档（改动前按需查阅）：
- `PRD.md` — 产品需求与验收标准
- `design.md` — 架构决策记录
- `README.md` / `README.zh-CN.md` — 面向用户的说明
- 交互原型：根目录 `PM Copilot 交互原型 v4 · TraeWork.html`（浅色）/ `…Dark.html`（深色）

## 目录结构与路径陷阱

```
仓库根（当前目录）
└─ pm_worker/pm_worker/              ← Xcode 工程根（pm_worker.xcodeproj 在这层）
   ├─ pm_worker/                     ← 真正编译的源码树
   │  ├─ pm_workerApp.swift
   │  ├─ 1-Presentation/             ← SwiftUI 三栏 UI + DS 设计系统（DS/ 子目录）
   │  ├─ 2-Orchestration/            ← 手写状态机 PipelineEngine、各 Store、MCP server runner
   │  ├─ 3-Agents/                   ← 各阶段 Agent prompt 与产物解析
   │  ├─ 4-CrossCutting/             ← ContextBuilder、Memory、Retrieval、Knowledge、LLM/SSE、WebTools
   │  ├─ 5-Storage/                  ← PMAgentStore（文件系统事实源）、GRDB 索引、模型
   │  └─ Resources/                  ← 14 个技能、PRD 模板、mermaid.min.js、字体
   ├─ pm_workerTests/                ← 单元测试
   ├─ Vendor/GRDB、Vendor/mcp-swift-sdk  ← 本地 SPM 包（离线构建）
   └─ Tools/MCPEchoSpike/            ← 早期 stdio 验证 spike（含 .build，勿全量搜索）
```

**路径陷阱（必读）：**
- 真实源码在 `pm_worker/pm_worker/pm_worker/`。与 xcodeproj 同级的 `pm_worker/pm_worker/ContentView.swift` 是 M0 残留，**不在构建里，勿改勿参考**。
- 构建目录有两个 `pm_worker` 嵌套层，所有命令以 `pm_worker/pm_worker/` 为 cwd。
- 工程是 PBXFileSystemSynchronizedRootGroup：源码树内新增文件自动进构建；资源放 `Resources/` 下即自动打包（目录会被拍平，如 `Resources/vendor/mermaid.min.js` → bundle 根的 `mermaid.min.js`）。

## 构建与测试命令

```bash
# 前置：xcode-select 指向 CommandLineTools，必须显式指 Xcode 工具链
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 构建（在 pm_worker/pm_worker/ 下执行）
xcodebuild -project pm_worker.xcodeproj -scheme pm_worker -configuration Debug build

# 全量测试（必须串行！并行会用例跨进程、行为异常）
xcodebuild -project pm_worker.xcodeproj -scheme pm_worker test -parallel-testing-enabled NO

# 单个测试类
xcodebuild ... test -only-testing:pm_workerTests/ContextBuilderTests
```

- `testDeepSeekLiveStreamChat` 是真连网 live 测试，本机 Keychain key 无效时 401 失败属环境问题，与代码改动无关，不计为回归。
- **完成任何改动后的验收标准：构建通过 + 全量测试绿（对照改动前的绿数，只增不减）**，再冒烟启动/退出一次确认无新崩溃（`~/Library/Logs/DiagnosticReports` 无新增 ips）。

## 沙盒与网络（执行环境）

- `xcodebuild`/`swiftpm` 需要写 `~/Library/org.swift.swiftpm` 等，沙盒内会失败——须在非沙盒模式运行这些命令。
- 构建完全离线（依赖全在 `Vendor/`）。需要拉外网资源（如 GitHub raw）时走本机代理 `http://127.0.0.1:15236`。
- **绝对不要改 macOS 系统代理设置**（Wi-Fi 的 HTTP/HTTPS/SOCKS 指向 Veee 127.0.0.1:15236/15235），误改会断网。

## Swift 并发铁律（本项目最大的坑源）

工程开启了 Xcode 26 默认 **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**——模块内所有类型隐式 @MainActor。由此产生三条强制规则：

1. **存储层类型显式 `nonisolated`**：被 GRDB 读写闭包、MCP 无头 Task 等 nonisolated 上下文用到的类（AppDatabase、PMAgentStore）必须显式 `nonisolated`，否则 isolated-deinit 触发 malloc「pointer being freed was not allocated」崩溃。
2. **必须保持 @MainActor 的 ObservableObject（会在 switchContext 中被替换销毁，如 PipelineEngine、MemoryStore），类体内显式写 `nonisolated deinit {}`**——退出隔离销毁路径，否则局部实例销毁即崩。
3. **被 nonisolated 上下文用到的值类型/枚举一律显式 `nonisolated struct/enum`**（MemoryEntry、ProjectDocument、DecisionRecord 等）。注意：**extension 不继承 nonisolated，须单独标 `nonisolated extension Foo`**。泛型传枚举做 DSTabItem 这类 Identifiable/Hashable 合成也有隔离坑，同样显式 nonisolated。

其他 Swift 坑（都真实踩过）：
- `foregroundStyle` 里三元隐式成员语法（`x ? .ink900 : .ink500`）会让重载解析崩溃、报错误导到别处——**必须写全 `Color.ink900`**。排查法：闭包内容替换成最小复现二分。
- GRDB 7：列默认值 `.defaults(to:)`；索引用表外 `db.create(indexOn:columns:)`；`write` 闭包参数是普通 `let Database`。
- mcp-swift-sdk `Tool.Content.text(...)` 工厂已弃用，写全枚举 case：`.text(text: x, annotations: nil, _meta: nil)`。
- `WKPreferences.javaScriptEnabled` 弃用（macOS 11+），改 `config.defaultWebpagePreferences.allowsContentJavaScript = true`。
- `[Float]→Data` 别用 `UnsafeBufferPointer(start:)` 悬垂指针，用 `vector.withUnsafeBufferPointer { Data(buffer: $0) }`。
- IDGenerator 等跨线程工具：nonisolated + NSLock + `nonisolated(unsafe)` 静态可变量。
- 带 `.textSelection(.enabled)` 的 `Text` 上**禁止挂 `.mask` / `.drawingGroup` 等 compositing 修饰符**（macOS 上 Text 被拍平成图层，拖选交互静默失效——用户气泡曾因此永远选不中）。折叠渐隐等视觉效果改用 overlay 淡入底色 + `.allowsHitTesting(false)`。改后冒烟必查：消息文字能鼠标拖选。

## UI 约定（DS 设计系统）

所有界面必须用 `1-Presentation/DS/` 的令牌与组件，**禁止系统默认控件**（ProgressView / 系统 Toggle / `.secondary` 前景等残留要清零，新增代码零引入）：

- 颜色：`DS.swift` 的语义令牌（ink / surface / overlay / border / brand / status / userBubble / shadowInk / scrim…）。深色模式由 `Color.dynamic(light:dark:)` 工厂全量自适应，调用点无需判断 colorScheme。
- 组件：`DSComponents*.swift`（DSButtonStyle / dsInput / dsCard / DSTabs / DSSwitch / DSSelect / DSSlider / DSDialog / DSMenu / DSTable / DSTag / DSNotif / DSSkeleton / DSAvatar / DSKbd / DSBreadcrumb / .ds-drawer / .ds-code…）。
- 图标（2026-09-15 改版）：`DSIcon.swift` 是唯一入口，内部渲染 **SF Symbols**（`Image(systemName:)` 仅允许出现在 DSIcon.swift 内部，调用点一律写 `DSIcon(.name, size:)`）。新图标 = 在 `extension DSIcon.Name` 加一行 `static let foo = DSIcon.Name(symbol: "sf.name")`；个别品牌字符（agent 机器人头像、markdown 徽标）保留自绘 path 兜底。
- 字体：`DS.Font.*` 令牌（body 12–15、heading 17–34、display 系 New York 衬线、mono 系 JetBrains Mono）。
- 动效：`DS.Motion.spring`，不用 easeOut/easeInOut。
- **DS 令牌已与原型 v4 CSS 值有意分歧**（「高级感升级」：冷调微染、双层阴影、衬线大字）——**不要「还原」回原型原值**。设计基调 = 保留 TraeWork 品牌骨架的 Branded Native。
- 需查原型 Dark 值时：HTML 原型 235KB 超 Read 限制，用 Grep 抓 `^\s*--[\w-]+:` 提取 CSS 变量段；组件样式多在 JS 函数体里。

## 产品级约定

- **UI 改动双份维护**：ModelConfigPage 与 SettingsView 模型 Tab 是同构双份，改一处同步另一处（既有惯例）。
- 功能导航页（技能库/知识库/决策日志）是独立整页，右栏 Inspector 仅 chat/home 渲染；`ContentView` 的 `showsInspectorPanel` switch 里勿引用已移除的 `modelConfig` case。
- 记忆抽屉是右缘滑出（overlay + transition），不是 sheet。
- 外观切换持久化：`AppearanceMode`（storageKey `pm.worker.appearance`）。
- 用户数据目录 `~/PMAgent/`：纯 Markdown/JSONL 文件 + 可重建索引，索引重建逻辑必须保持「删库可重建」不变量。

## 工作方式

- 改前先读目标文件最新状态（跨会话可能有并发写盘，行号会漂移；怀疑时 `ps aux | grep xcodebuild` 查遗留构建）。编辑 old_string 失配时重读文件，勿盲目重试。
- 增删 UI 控件后用 Grep 清点系统控件残留（`ProgressView|Toggle(`；`systemName:` 仅 DSIcon.swift 白名单内允许）。
- 提交信息遵循仓库现有风格（简短中文/英文均可，聚焦 why）。
- 里程碑状态见 README「Roadmap & status」；M5（MCP + 收尾）进行中。
