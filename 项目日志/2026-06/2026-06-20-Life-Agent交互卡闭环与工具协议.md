# 2026-06-20 Life-Agent 交互卡闭环与工具协议

## 背景

当前分支是 `life-agent`。本轮目标是把日期/提醒 Agent 从“模型输出卡片，App 再本地猜执行动作”调整为“模型显式给出交互卡和选项动作，用户点选后 App 直接执行对应工具”。

同时，模型调用统一切到 `deepseek-v4-pro`，方便后续围绕同一个模型调试提示词和工具协议。

## 本次调整

- `CardOption` 扩展为可携带 `actions`、`next_step`、`result_card`，让模型可以把用户点选后的执行动作直接挂在选项上。
- 用户点击确认选项时，优先执行该选项自带的 `actions`，不再用 `option.value` 临时构造空参数工具计划。
- 支持 `finish`、`continue_loop`、`wait_for_more_info` 三种闭环状态：
  - `finish`：执行完动作后结束本轮。
  - `continue_loop`：执行后把用户选择和工具结果重新送回模型判断。
  - `wait_for_more_info`：留在卡片内等待用户补充信息。
- 系统提示词中的“场景处理规则”改成“交互示例”，避免把生日、喝水、充值等场景硬编码成强规则。
- 工具协议对齐为 `card.ask_user`、`memory.save`、`calendar.create_event`、`reminder.create`、`notification.schedule`、`lunar_series.create`、`artifacts.cancel`、`counter.add`。
- 未知工具不再静默降级成普通记录，而是抛出 `unsupportedTool`，便于在调试视图暴露模型和 App 工具协议不一致的问题。
- 模型失败或 JSON 解析失败时，本地兜底只保存普通记录，不再调用本地生日/日期解析抢模型决策。
- 通用日期提醒优先读取模型参数，例如 `title`、`date`、`start_date`、`time`、`repeat_rule`、`remind_before_days`。
- 修复通用提醒被命名成“生日”的问题，例如“喝水”不会再创建成“喝水生日”。
- `calendar.create_event` 明确走日历；`reminder.create` 明确走提醒事项，减少不必要的双写。
- 对话调试视图会显示实际请求模型名，便于确认当前请求确实走 `deepseek-v4-pro`。

## 关键文件

- `Jotly/JotlyModels.swift`
- `Jotly/JotlyHomeViewModel.swift`
- `Jotly/JotlyServices.swift`
- `Jotly/JotlyHomeScreen.swift`

## 当前行为约定

- 模型是语义决策者，App 不再用本地规则覆盖模型正常判断。
- 写入 iOS 日历、提醒事项、通知前仍需要用户确认。
- 如果模型已经能确定某个选项背后的动作，应把动作直接挂到该选项的 `actions` 里。
- 用户删除卡片时，仍沿用 artifacts 撤销链路，撤销由本 App 创建的系统对象。
- 小米 MIMO ASR 本轮只按充值恢复后重新验证，不做 provider 自动降级。

## 验证记录

已通过通用真机 iOS 构建：

```bash
xcodebuild -project /Users/gaoxingchen/Documents/Jotly/Jotly/Jotly.xcodeproj -scheme Jotly -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/JotlyDerivedData CODE_SIGNING_ALLOWED=NO build
```

结果：`BUILD SUCCEEDED`

## 后续重点

- 真机验证 MIMO 充值恢复后的语音识别链路。
- 用对话调试模式检查模型实际输出的 `card.options[].actions` 是否稳定。
- 用流程图模式观察 `input -> prompt -> model -> decode -> confirm -> tool -> finish` 每个节点是否符合预期。
- 如果模型输出未知工具，优先改提示词或工具映射，不要再静默假成功。
