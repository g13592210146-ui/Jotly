# Memory OS 迁移计划

## 当前分支状态

`feature/memory-os` 当前已完成数据库底座、长期记忆写入和两阶段检索回复主链路：

- 已完成：SQLite/GRDB、核心表、旧 JSON 单次迁移、FTS5、Qwen Embedding、Qwen Rerank、异步索引恢复、`need_memory` 两阶段 Agent、`reply` 回复卡片。
- 后续增强：实体抽取与关系查询、独立 Repository、sqlite-vec/ANN 大规模向量索引、完整 Run 恢复器。
- 当前原则：先保持现有业务与 UI 不变，再按阶段替换调用方；不在第一阶段同时重写 Agent Loop。

## 阶段 1：数据库替换

- 接入 GRDB 和 SQLite。
- 建立 RawEvent、Message、AgentRun、Card、ActionLog 表。
- 迁移旧 JSON，不删除用户原始文件。
- `LocalStore` 改为数据库兼容门面。
- 保持首页、快捷指令、日期工具和调试链路可用。

验收：旧用户升级后卡片数量一致；新输入不再改写 `jotly_store.json`；构建通过。

## 阶段 2：Memory Layer

- `memory.save`、`memory.update` 写入 `memory_items`。
- 增加实体、关系和来源链接。
- 增加结构化查询与 FTS5。

验收：Memory 可独立于 Card 查询和更新；删除 Card 不丢 Memory。

## 阶段 3：Agent Context

- 增加 Memory Prefetch。
- 增加 ContextBuilder。
- 支持最近消息、热记忆、预取记忆和工具状态统一装载。

验收：每次 Run 可追溯实际装载的上下文，缓存前缀保持稳定。

## 阶段 4：Embedding

- 接入 Qwen Embedding。
- 增加 `memory_embeddings`。
- 评估 sqlite-vec 真机兼容性后启用向量搜索。

验收：同义表达可以召回对应 Memory，结构化结果优先于向量结果。

## 回滚

- 数据库迁移前保留原 JSON。
- Migration 失败时继续使用 JSON fallback，不覆盖原文件。
- 每次 schema 变更只新增 GRDB migration，不修改已发布 migration。
