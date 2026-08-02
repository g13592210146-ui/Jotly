# 贡献指南

感谢你想帮助 Jotly。这个项目仍在快速迭代，最有价值的贡献通常不是增加更多按钮，而是让一条真实生活输入更可靠、更容易理解、更容易恢复。

## 提交 Issue 前

- 先搜索已有 Issue，确认不是重复问题。
- 一个 Issue 只描述一个问题或一个可验证的用户场景。
- 说明设备、系统版本、输入方式（文字/语音/图片）、模型和语音 Provider。
- 提供最短复现步骤、实际结果和期望结果。
- 日志和截图必须移除 API Key、Access Token、个人信息、地址和原图。

## 提交 Pull Request 前

- 从最新 `main` 创建分支，分支名说明目的，例如 `fix/voice-first-frames`。
- 不提交 `LocalSecrets.plist`、`local.properties`、DerivedData、个人截图或真实用户数据。
- 保持小步提交；一个 PR 尽量只解决一个问题。
- 提示词修改要说明为什么改、对哪些场景有影响，以及是否有评测或回归结果。
- 区分构建证据和设备证据：`BUILD SUCCEEDED` 不等于真机语音、相机或提醒已通过。

## 本地检查

```bash
xcodebuild -project Jotly.xcodeproj -scheme Jotly \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/JotlyDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

如果改动 Android，请在 `JotlyAndroid/` 下运行：

```bash
./gradlew assembleDebug
```

## 代码和产品原则

1. 模型负责理解和选择，程序负责权限、协议、事务和安全边界。
2. 不用关键词堆砌或提示词硬编码来伪装 Agent 能力。
3. 用户输入应先保存，再处理；后台任务要能重试和恢复。
4. 卡片是结果展示，不是数据库；记忆、原始输入和工具动作必须可追溯。
5. 调试脚手架与面向用户的 App 保持边界，避免把调试内容泄露到普通卡片。

## 评审重点

维护者会重点看：行为是否可复现、失败是否可恢复、是否影响既有场景、是否新增隐私风险、测试是否覆盖边界，以及日志是否让下一位维护者能接手。
