# 2026-06-29 快捷入口改为 Shortcuts 搜索引导

## 修改文件
- `Jotly/JotlyHomeScreen.swift`

## 变更点
- 将“截图 / 语音”入口页上的按钮从 `shortcuts://create-shortcut` 改为打开 Shortcuts 应用本体。
- 将页面文案改为明确提示用户在 Shortcuts 中搜索 `Jotly`，再手动添加 `截图` 和 `语音` 动作。
- 保留系统动作本身不变，只修正入口页的误导性跳转。

## 验证结果
- 已执行 iOS 真机构建验证，结果 `BUILD SUCCEEDED`。
