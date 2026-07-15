# Jotly Memory OS 数据架构

## 目标

Memory OS 把 Jotly 的数据中心从 `MemoryCard + jotly_store.json` 调整为可追溯的事件数据库：

```text
RawEvent -> Message -> AgentRun -> Memory / Business Object -> Card Projection
```

现有 Agent JSON 协议、工具执行和卡片 UI 暂时保留。第一阶段只替换数据底座，不改用户可见业务流程。

## 核心边界

| 层 | 职责 | 不是 |
| --- | --- | --- |
| RawEvent | 不可变地保存用户原始输入及附件引用 | 卡片内容 |
| Message | 保存 user / assistant / tool 对话消息 | UI 临时状态 |
| AgentRun | 记录一次 Agent 循环、状态和工具计划 | 模型配置 |
| MemoryItem | 保存可长期检索的事实、事件、偏好、任务和关系 | 所有输入的复制品 |
| Business Object | 保存提醒、日程、计数等可执行对象 | Memory 文本 |
| Card | Memory 和业务对象的 UI 投影 | 数据本体 |
| ActionLog | 记录工具执行过程及结果 | 调试文案 |

## 第一阶段表

- `schema_metadata`：迁移标记和数据库元信息。
- `conversations`：对话容器。
- `raw_events`：语音、文字、图片、截图等原始输入。
- `messages`：user / assistant / tool 消息。
- `agent_runs`：Agent 运行状态、记忆需求和工具计划。
- `cards`：卡片投影，完整 UI payload 暂存于 `content_json`。
- `card_message_links`：卡片与触发、响应、确认消息的关系。
- `action_logs`：工具调用状态、参数和结果。
- `shortcut_operations`：快捷指令运行状态。
- `birthday_events`、`reminder_tasks`：现有日期业务对象兼容表。

## Memory 表

- `memory_items`
- `entities`
- `entity_relations`
- `memory_entity_links`
- `card_memory_links`
- `memory_embeddings`

这些表在第一版 schema 中建立，第二阶段接入 Memory Ingestion、FTS5 和向量检索。

## 兼容策略

`LocalStore` 暂时保留，但只作为兼容门面：

1. 初始化 SQLite 并执行版本迁移。
2. 首次启动读取 `jotly_store.json`，事务式迁入 SQLite。
3. JSON 保留为只读备份，不再作为主存储继续写入。
4. 现有首页、快捷指令和工具层继续调用 `LocalStore`，减少一次性重写风险。
5. 新模块直接依赖 Repository，后续逐步移除 `LocalStore`。

## 删除语义

- 删除 Card：只删除 UI 投影和卡片链接，不删除 RawEvent、Message、MemoryItem。
- 删除 MemoryItem：标记状态，不回删 RawEvent。
- 删除业务对象：由对应工具执行器撤销系统资源并更新 ActionLog。

## 搜索演进

1. SQL 结构化查询：日期、金额、次数、状态。
2. FTS5：自然语言关键词和历史文本。
3. 实体图谱：人物、地点、品牌及关系。
4. Embedding + sqlite-vec：语义相似检索。

