# Jotly

Jotly 是一个 iOS 原生的语音随手记应用，核心流程是：

`长按说话 -> 实时转写 -> 生成卡片 -> DeepSeek 分析 -> 选择题式确认 -> 工具执行 -> 结果回显`

## 接手顺序

新模型或新开发者接手时，按这个顺序看：

1. [`AI_USER_STORY.md`](./AI_USER_STORY.md)
2. [`DESIGN_GUIDELINES.md`](./DESIGN_GUIDELINES.md)
3. [`项目日志/README.md`](./项目日志/README.md)
4. `JotlyHomeScreen.swift`
5. `JotlyHomeViewModel.swift`
6. `JotlyServices.swift`
7. `JotlyModels.swift`

## 本地密钥配置

仓库不保存任何 API Key。首次运行前：

1. 复制 `Jotly/Config/LocalSecrets.example.plist` 为 `Jotly/Config/LocalSecrets.plist`。
2. 在本地文件中填写需要使用的模型和语音服务密钥。
3. 不要提交 `LocalSecrets.plist`；该文件已加入 `.gitignore`。

运行时也可以通过同名环境变量，或应用使用的 `UserDefaults` 配置项提供密钥。

## 版本管理

当前已经建立第一个可回滚版本，方便后续按不同分叉继续调试：

- Git commit: `9c3ca39`
- Git tag: `input-dock-v1`

这个版本对应当前“底部输入框 / 输入 dock”状态。后续如果要试不同方向，建议直接基于这个 tag 分叉，不要在它上面反复堆改。

## 当前语音测试分支

当前语音 Provider 测试实现线来自 `feature/mimo-asr`，当前 `feature/voice-mvp` 已合并这条实现线，不影响 `input-dock-v1` 基线版本。

- Provider 切换入口：顶部 `Apple / MIMO / 豆包 / 阿里`
- MIMO 当前策略：录音期间只缓存音频，松手后一次性提交完整 WAV，避免流式重复识别同一句话
- 豆包当前状态：已接入基于 Seed/WebSocket 的实时链路，使用当前测试凭据和候选 ResourceId，后续主要看运行日志里的鉴权和回包解析
- 阿里云当前状态：已接入 `Jotly/Frameworks/nuisdk.framework` 真机版，并通过通用 iOS 真机构建；模拟器运行仍需要额外 SDK slice
- 分支详情见 [`项目日志/2026-06-16-语音识别Provider测试分支.md`](./项目日志/2026-06-16-语音识别Provider测试分支.md)

## 当前维护原则

- 需求变化、卡点、尝试过的方案，优先写入 `项目日志/`
- 视觉规范和版本兼容约束，优先写入 `DESIGN_GUIDELINES.md`
- 产品故事、闭环范围、MVP 边界，优先写入 `AI_USER_STORY.md`
- 新增可复用的约定，优先写成文档，不只留在聊天记录里
- 项目日志建议先更新 `项目日志/README.md`，再新增具体条目，避免目录越来越散

## Memory OS 数据原则

1. Card 不是数据库，Card 是 Memory 的展示层。
2. 所有用户输入必须先进入 RawEvent。
3. 所有 Agent 运行必须产生 AgentRun。
4. 所有长期信息必须进入 MemoryItem。
5. Memory 必须可以追溯来源 Message。
6. 删除 Card 不等于删除 Memory。
7. 删除 Memory 不等于删除原始输入。
8. 所有工具调用必须记录 ActionLog。
9. 所有异步任务必须可恢复。
10. 数据结构优先于 UI。

详细设计见 [`docs/MemoryOS/ARCHITECTURE.md`](./docs/MemoryOS/ARCHITECTURE.md) 和 [`docs/MemoryOS/MIGRATION_PLAN.md`](./docs/MemoryOS/MIGRATION_PLAN.md)。

## 运行日志渠道

这个项目需要同时看两类日志：

### 1. Xcode / Simulator 运行日志

- 用 Xcode 的 Console 看 App 运行时输出
- 按 `subsystem == com.xingchen.Jotly` 过滤
- 关注 `app`、`speech`、`deepseek`、`storage`、`tool` 这些 category

### 2. 编译日志

- 用 `xcodebuild` 或 Xcode Build 输出判断编译是否成功
- 如果出现语音、权限、网络、卡片状态问题，优先看最近一次构建和运行日志

## 调试约定

- 每次改动后，先编译验证
- 语音识别、DeepSeek、提醒创建这三条主链路都要能从日志里定位状态
- 如果运行态有异常，先看日志，再改代码

## 当前目标

第一期只保证生日提醒闭环和兼容性，不扩展复杂业务。
