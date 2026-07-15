# 2026-06-27 DeepSeek V4 Flash 分立思考与非思考版本

## 修改的文件
- **系统源文件**：
  - [JotlyModels.swift](file:///Users/gaoxingchen/Documents/Jotly/Jotly/Jotly/JotlyModels.swift)
  - [JotlyDeepSeekClient.swift](file:///Users/gaoxingchen/Documents/Jotly/Jotly/Jotly/JotlyDeepSeekClient.swift)

## 修复的问题与变更点

### 1. 模型列表支持分立的 V4 Flash 模式选型
- **成因**：为了方便对比在 DeepSeek V4 Flash 模型下开启或关闭“思考模式（Reasoning）”对响应速度、Token 消耗以及 JSON 解析鲁棒性的影响，用户需要能够从列表里自由切换这两个变体。
- **修复**：
  - 在 [JotlyModels.swift](file:///Users/gaoxingchen/Documents/Jotly/Jotly/Jotly/JotlyModels.swift) 中新增了选型：`deepseekV4FlashThinking = "deepseek-v4-flash-thinking"`。
  - 将原来的选项分别精细命名为：
    - `DeepSeek V4 Flash (非思考)`：默认选项，关停思考输出。
    - `DeepSeek V4 Flash (思考)`：开启官方思考输出。
  - 对新选型补全了与原 V4 Flash 等同的 Token 计价（输入 ¥1/M，缓存 ¥0.02/M，输出 ¥2/M）以及小米 MiMo、阿里云等开关映射分支。

### 2. 双模式底层请求体差异化封装
- **修改**：在 [JotlyDeepSeekClient.swift](file:///Users/gaoxingchen/Documents/Jotly/Jotly/Jotly/JotlyDeepSeekClient.swift) 中实现了：
  - **`apiModelName(for:)` 路由**：当选择 `deepseekV4Flash` 或 `deepseekV4FlashThinking` 时，底层的 `model` 字段一律被映射和转译为官方 API 认可的 `"deepseek-v4-flash"` 模型名。
  - **`thinkingConfig(for:)` 差异化**：
    - 当为 `deepseekV4Flash` 时，下发 `"thinking": {"type": "disabled"}`。
    - 当为 `deepseekV4FlashThinking` 时，下发 `"thinking": {"type": "enabled"}`。

## 验证结果
- **编译测试**：项目在 generic iOS 目标下编译构建成功：
  ```bash
  xcodebuild -project Jotly.xcodeproj -scheme Jotly -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
  ```
  输出：`** BUILD SUCCEEDED **`
