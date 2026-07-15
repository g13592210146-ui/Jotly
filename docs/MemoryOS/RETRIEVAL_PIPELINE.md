# Memory OS 读写与回复链路

## 用户可见结果

- 普通记录、偏好、关系和事件仍按原有 Agent 流程生成卡片。
- 模型判断内容值得长期记住时，主卡片先完成，记忆随后在后台写入并生成向量。
- 用户查询过去的信息时，模型先生成检索词，Memory OS 检索后再交给模型组织答案。
- 最终使用 `reply` 回复卡片，只展示回答正文，不显示任务状态、标题、按钮或工具信息。

## 写入链路

```text
用户输入 -> Agent 主流程 -> 卡片完成
                         -> memory_to_save
                              -> 后台保存 memory_items
                              -> text-embedding-v4 生成 256 维向量
                              -> memory_embeddings
```

写入规则：

1. 只有模型明确放入 `memory_to_save` 的稳定事实、事件、偏好、关系或任务摘要才进入长期记忆。
2. 查询、闲聊和回复本身不写入记忆。
3. 数据库按“类型 + 完整内容 + 5 分钟窗口”幂等，避免 `memory.save` 与 `memory_to_save` 重复写入。
4. 卡片完成不等待向量接口；向量失败只标记 `failed`，不影响主流程。
5. App 再启动时恢复 `pending / failed / 超时 running`，但不处理 `legacy`。

## 旧数据策略

- 升级前已经存在的 `memory_items` 标记为 `legacy`。
- `legacy` 可以通过 FTS/文本检索被找到，但不会补算向量。
- 升级后新增的记忆标记为 `pending`，仅这些数据进入向量队列。

## 查询链路

```text
用户提问
  -> 第一次模型调用：need_memory + memory_query
  -> 并行候选召回
       - FTS5 中文三字滑窗
       - LIKE 短词兜底
       - text-embedding-v4 语义向量
  -> qwen3-vl-rerank 重排候选
  -> 第二次模型调用：只依据检索结果回答
  -> reply 卡片
```

降级规则：

- 向量接口失败：继续使用 FTS/LIKE。
- rerank 失败：使用本地文本/向量综合顺序。
- 没有命中：明确回复“没有找到相关记忆”，禁止编造。

## 数据追溯

- 新记忆保存来源 `Message / RawEvent`。
- 记忆写入卡片通过 `card_memory_links(projection)` 关联。
- 查询命中的记忆通过 `card_memory_links(retrieval_source)` 关联到回复卡片。
- `agent_runs` 记录本轮 `need_memory` 和 `memory_query`。
- 调试流程显示记忆节点、命中数量、是否使用向量和 rerank。

## 性能策略

- 数据库进程内只初始化一次，迁移不再被多个 `LocalStore` 重复执行。
- 首屏只读取最近 30 张卡片，滚动到底后每次再取 30 张。
- 首屏查询不加载历史 RawEvent、生日对象和提醒 payload。
- 农历维护延迟到首屏稳定后在后台执行。
- 相册数据源和缩略图缓存跨弹窗复用，单个缩略图只刷新自己的单元格。
- 相机移除人为的 0.35 秒等待。

