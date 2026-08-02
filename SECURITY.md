# 安全与隐私

## 不要公开提交的内容

- API Key、Access Token、Gateway Token、Cookie 和私钥；
- `Jotly/Config/LocalSecrets.plist`、`JotlyAndroid/local.properties`；
- 真实用户输入、记忆数据库、图片原图和包含个人信息的调试日志；
- 生产服务器环境文件和部署凭据。

## 发现疑似泄露怎么办

不要在公开 Issue、PR 或聊天中贴出密钥。先立即在对应服务商后台撤销/轮换，再通过仓库维护者的私下渠道报告问题，并说明受影响的提交或文件。

## 本地配置

iOS 使用被 Git 忽略的 `LocalSecrets.plist`、环境变量或运行时设置；Android 使用被 Git 忽略的 `local.properties`。示例配置只包含空值，不应填入真实凭据后提交。

## 设计边界

Jotly 目前是个人 Life Agent 原型，不应被当作医疗、财务或安全关键系统。模型输出需要经过 App 的权限、确认和数据校验；网络请求失败时，应用应保留用户输入并明确告知状态。
