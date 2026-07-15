# Liquid Glass 设计准则

> Jotly 项目 UI 编码参考 | 基于 Apple 官方文档整理

---

## 版本兼容

**所有 Liquid Glass API 最低要求 iOS 26.0+**，iOS 18 及更低版本不可用。

**兼容策略**：

- **标准组件**（`TabView`、`NavigationStack`、`Toolbar` 等）无需任何处理——在 iOS 18 上自动回退为系统原生样式（毛玻璃/扁平化），不会崩溃
- **Liquid Glass 专属 API**（`glassEffect`、`.glass` 按钮样式、`backgroundExtensionEffect`、`UIGlassEffect` 等）必须用 `if #available` 包裹，并为低版本提供回退实现

```swift
// SwiftUI 示例
if #available(iOS 26, *) {
    content.glassEffect(.regular, in: .capsule)
} else {
    content.background(.ultraThinMaterial)
}

// UIKit 示例
if #available(iOS 26, *) {
    let glassEffect = UIGlassEffect()
    // ...
} else {
    let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
    // ...
}
```

**需要版本判断的 API**：`glassEffect`、`.glass`/`.glassProminent`/`.glass(_:)`、`UIGlassEffect`、`backgroundExtensionEffect`、`UIBackgroundExtensionView`、`safeAreaBar`、`UIScrollEdgeElementContainerInteraction`、`UITabBarController.MinimizeBehavior`、`UITabBarController.Mode.tabSidebar`、`ConcentricRectangle`、`UICornerConfiguration`

**无需版本判断的 API**：`TabView`、`NavigationStack`、`NavigationSplitView`、`Toolbar`、`.scrollEdgeEffectStyle`、标准材质（`ultraThinMaterial` 等）、`UIBlurEffect`、`UIVibrancyEffect`、SF Symbols

---

## 核心概念

Liquid Glass 是 Apple 全平台统一的设计语言，为控件和导航元素形成独立的功能层，悬浮在内容层之上。SwiftUI/UIKit 标准组件自动采用此材质，无需额外配置。

**两层架构**：
- **控件/导航层** → Liquid Glass（Tab Bar、Toolbar、Sidebar、Sheet、Popover）
- **内容层** → 标准材质（`ultraThin` / `thin` / `regular` / `thick`）

**两种变体**：
- `Glass.regular` — 模糊背景保持可读性，适用于大多数场景（alerts、sidebars、popovers）
- `Glass.clear` — 高度半透明，仅用于悬浮在照片/视频等媒体背景上的组件；底层较亮时需加 35% 不透明度暗色遮罩

**例外**：内容层中的 Slider、Toggle 在用户激活时可呈现 Liquid Glass 外观。

---

## 编码规则

### 不要做的事

- 不要在内容层使用 Liquid Glass（用标准材质）
- 不要给控件和导航元素加自定义背景（会干扰系统 Liquid Glass 和滚动边缘效果）
- 不要对多个自定义控件滥用 `glassEffect`（仅限最重要的功能元素）
- 不要将 Liquid Glass 元素互相堆叠
- 不要为多个按钮背景同时着色
- 不要在 `thin`/`ultraThin` 材质上使用 `quaternaryLabel` vibrancy
- 不要用应用名称作为窗口标题

### 必须做的事

- 自定义颜色必须提供 light / dark / high contrast 三套变体
- 内容延伸至屏幕边缘；控件浮在内容之上
- 控件圆角与容器同心对齐（`ConcentricRectangle` / `UICornerConfiguration`）
- Tab Bar 图标使用 SF Symbols 填充样式，包含文字标签
- 主要操作按钮使用 `.glassProminent` / `.prominentGlass()`，仅指定一个，放尾随侧
- 着色时将颜色应用于按钮背景而非文字/符号

---

## SwiftUI API 速查

### Liquid Glass 效果

```swift
.glassEffect(.regular, in: .rect(cornerRadius: 16))  // Regular 变体
.glassEffect(.clear, in: .capsule)                    // Clear 变体
```

### 按钮样式

```swift
.buttonStyle(.glass)              // 标准
.buttonStyle(.glassProminent)     // 突出，用于 Done/Submit 等主要操作
.buttonStyle(.glass(.clear))      // 透明变体
```

### 布局与导航

```swift
.backgroundExtensionEffect()                              // 背景延伸至 Sidebar/Inspector 下方
.safeAreaBar(edge: .bottom)                                // 自定义 Bar 注册滚动边缘效果
.scrollEdgeEffectStyle(.automatic)                         // 滚动边缘效果
.tabViewStyle(.sidebarAdaptable)                           // Tab Bar ↔ Sidebar 自适应
NavigationSplitView { ... }                                // Split View 布局
.inspector(isPresented: $showInspector) { ... }           // Inspector 面板
ConcentricRectangle(cornerRadius: 12)                      // 同心圆角
```

### 标准材质（内容层）

```swift
.ultraThinMaterial / .thinMaterial / .regularMaterial / .thickMaterial
```

---

## UIKit API 速查

### Liquid Glass 效果

```swift
let glassEffect = UIGlassEffect()  // 配合自定义视图使用
```

### 按钮配置

```swift
var config = UIButton.Configuration.filled()
config.glass()                      // 标准
config.prominentGlass()             // 突出
config.clearGlass()                  // 透明
config.prominentClearGlass()         // 突出透明
```

### 布局与导航

```swift
UIBackgroundExtensionView()                                  // 背景延伸视图
UIScrollEdgeElementContainerInteraction()                    // 滚动边缘效果容器
UITabBarController.MinimizeBehavior                          // Tab Bar 最小化
UITabBarController.Mode.tabSidebar                          // Tab ↔ Sidebar 自适应
UISplitViewController.Column.inspector                       // Inspector 列
view.cornerConfiguration = UICornerConfiguration(...)        // 圆角配置
```

### 标准材质（内容层）

```swift
UIBlurEffect(style: .systemUltraThinMaterial / .systemThinMaterial / .systemMaterial / .systemThickMaterial)
UIVibrancyEffect(style: .label / .secondaryLabel / .tertiaryLabel / .fill / .secondaryFill / .tertiaryFill)
```

---

## 控件行为

- **Slider / Toggle**：交互期间旋钮自动变为 Liquid Glass（系统默认行为）
- **Button**：可流畅变形为菜单和弹出框
- **控件尺寸**：支持 `.extraLarge` 控件尺寸
- **Tab Bar**（iOS）：浮在屏幕底部，支持附件和最小化行为
- **Tab Bar**（iPadOS）：位于屏幕顶部，支持 `sidebarAdaptable` 转换为 Sidebar
- **Toolbar**：默认采用滚动边缘效果；项目分前导/中间/尾随三组；标题 ≤ 15 字符
- **菜单**：使用标准 selector（如 .copy, .paste）可自动获得系统图标
