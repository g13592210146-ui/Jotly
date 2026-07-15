# 2026-06-29 双列网格 Widget 排版与 ASR 语气优化

## 修改的文件
- `JotlyModels.swift`
- `JotlyDeepSeekClient.swift`
- `JotlyHomeViewModel.swift`
- `JotlyHomeScreen.swift`
- `JotlyHomeScreenSections.swift`

## 修复的问题与变更点

### 1. 正倒数日 & 习惯打卡双列 Widget 排版
- 在“正倒数日”与“习惯打卡”子分类下，将原本全宽的卡片替换为 **双列正方形 Widget 排版**，一行放置两个。
- 引入了自适应卡片图标提供者 `CardIconProvider`，能智能提取卡片标题内的关键字，为不同的打卡（如咖啡、早睡、运动）和不同的正倒数日（如比赛、考试、生日）分发特定的 SF Symbol 徽章及配色，不匹配的则显示默认的盾牌/闹钟缺省图标。
- Widget 内置了实时的正倒数天数换算展示和 MM-dd 格式的目标日期，习惯卡片则使用 compact 7x4 迷你日历打卡格直观表达当月进展，且圆点深浅随打卡次数变化。

### 2. 主子卡级联横滑布局
- 在全部卡片列表（`.all`）模式下，如果父级卡片存在派生的习惯打卡或倒计时子卡，我们会在父卡片下方以 `44pt` 对齐缩进的横向 `ScrollView` 排布这些正方形 Widget，完美展现主子级联逻辑关系。

### 3. 长按说话中间历史会话气泡回显
- 在卡片内部标题下方，增加了以微型聊天记录风格渲染的 `conversationMessages` 对话列表。它会自动滤除空文本，将前几次补充的用户发言和助手的系统回复交错呈现出来，让用户随时回溯长按卡片修改的中间脉络。

### 4. 语音 ASR 语气词模型优化
- 在 API 交互层结构中追加了 `optimizedUserText`（`optimized_user_text`）用于备用。
- 大模型会在不改变原意的前提下，优化过滤掉用户语音输入中的口语语气词（如“呃”、“啊”等卡顿），返回抛光后的干净文本。
- 客户端在接收到抛光文本后，会自动将其应用为卡片的 `originalText` 并展现在卡面上。

### 5. 倒数日立即执行及数据同步 Bug 修复
- 修复了在 `executeResolvedBirthdayAnalysis` 中卡片状态更新完成时由于 executablePlans 为空而导致 `completed.message` 停留在 `正在处理...` 的文案残余，支持将模型的最优完成文案回填写入。
- 修改了卡片在修改（`.cardRevision`）或以新习惯模式保存时的累加触发：打卡卡片每次长按修改后，会自动将今日日期追加到打卡历史里，完美实时递增“本月累计”。

## 验证结果
- 项目编译通过：
  ```bash
  xcodebuild -project Jotly.xcodeproj -scheme Jotly -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
  ```
  输出：`** BUILD SUCCEEDED **`
