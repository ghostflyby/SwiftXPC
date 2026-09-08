# XPCSession 体系迁移可行性研究

日期：2026-09-08 · 分支：`xpc-session-feasibility` · 环境：macOS 26.5 SDK（Swift 6.3.2，XPC overlay
user-module-version 128.120.2），探针在本机实际运行验证。

## 结论

**现阶段不迁移，把双传输层抽象作为 v3 架构预案。** session 模型在 macOS 14/15 部署目标上的
鉴权与可观测能力严格弱于现有 connection 路径，而迁移收益（reject 模型、rich error）不足以抵消。
重估触发条件见文末。

## 已验证可用（探针实跑通过）

探针程序完成三轮验证，全部成功：

1. **匿名 listener + endpoint + session 回复链路**：`XPCListener(targetQueue:options:
   incomingSessionHandler:)`（macOS 15，匿名）→ `.endpoint` → `XPCSession(endpoint:)` →
   `send(message:replyHandler:)` → 服务端 handler 返回 reply 字典 → 客户端收到。
   我们的 request/reply 模型可完整承载。
2. **显式拒绝**：handler 内 `request.reject(reason:)`，客户端经 cancellationHandler 观察到取消。
   这是 connection 模型没有的 accept/reject 能力。
3. **取消语义**：客户端 `cancel(reason:)` → 服务端 cancellationHandler 收到 `XPCRichError`
   （`canRetry=false`；`String(describing:)` 给出 "Underlying connection was invalidated.
   Reason: Client is gone"）。

### 裸对象桥接（我们的 marshal 管线适配点）

- overlay `XPCDictionary`：`init(_ xpc_object_t)` 裸构造 + `withUnsafeUnderlyingDictionary`
  作用域访问裸对象。raw 管线可适配（作用域式，契合我们的非持有模型）。
- `XPCEndpoint`：`init(_ xpc_endpoint_t)` 与 `var _endpoint: xpc_endpoint_t` 双向裸桥接。
  actor reference 的 endpoint 导出/导入可平移：`XPCListener.endpoint`（15+）替代
  `xpc_endpoint_create(listener)`。
- ⚠️ overlay `XPCDictionary` 与本库 `SwiftXPC.XPCDictionary` **同名冲突**，同文件需
  `XPC.XPCDictionary` 限定。

### 必须遵守的 API 契约（探针踩坑实录）

- `setCancellationHandler` 等只能作用于 **inactive** session；便捷 init（endpoint/machService）
  自动激活，**事后无设置窗口**——handler 一律通过 init 变体传入。
- `.inactive` listener 必须先 `activate()` 再接受连接。
- incomingSessionHandler 闭包必须返回 `Decision`（`accept(...)` 或 `reject(...)` 的结果）。

## 迁移收益

1. listener 的显式 accept/reject 模型（对应 Phase 6 鉴权接入点诉求）。
2. `XPCRichError` + cancellationHandler 的统一生命周期错误（`canRetry` 可支撑重试）。
3. 未来能力的唯一载体：`XPCPeerRequirement`（macOS 26+ 组合鉴权对象）、
   `XPCReceivedMessage.senderSatisfies`（逐消息鉴权）只存在于 session/listener overlay。
4. legacy connection API 已停止演进，session 是 Apple 的现行方向。

## 阻塞与损失（决策依据）

| 能力 | connection 模型（现状） | session 模型（overlay） |
|---|---|---|
| 对端身份（pid/euid/egid/asid） | `XPCConnection.pid` 等，已封装 | **完全缺失**（整个 overlay 接口零出现）|
| 字符串 code-signing requirement（macOS 12/14.4+） | 已封装，内核级强制 | **C-only 不可用**；overlay 仅 macOS 26+ 的 `setPeerRequirement`/带 requirement 的 init |
| TERMINATION_IMMINENT 可观测 | 专用 handler（本轮落地） | **不可观测**：该错误只投递 connection event handler；session 侧 cancel 的 `XPCRichError` 为不透明类型（仅 `canRetry`，无错误码），无法区分死因 |
| `shouldAccept` 自定义校验钩子 | 可用（pid/euid 输入） | 无输入可用（无身份 API），形同虚设 |
| invalidation reason 字符串 | 可用 | 无对应 |
| accept/reject、rich error、26+ 逐消息鉴权 | 无 | 有 |

结论：在部署目标 < 26 的前提下，迁移是**鉴权能力的净倒退**；本库 Phase 6 的核心目标恰是鉴权。

## 策略选项

- **A. 全量替换**：一次性迁移传输层。损失上表前三行，不推荐。
- **B. 双传输层抽象**：内部定义 Transport 协议（send/reply、bind、endpoint、identity
  capability 查询），connection 与 session 双实现，按部署目标与鉴权需求选择。
  工程量大但可逆，作为 v3 预案。
- **C. 混合桥接**（listener 收 session、桥回 connection）：**不可行**——XPCSession 无法
  取回底层 `xpc_connection_t`，两个对象体系不能互转。
- **D. 维持现状（当前选择）**：legacy connection API 无废弃标记，零成本等待。

## 重估触发条件

1. Apple 在 overlay 暴露对端身份 API（pid/euid）。
2. 最低部署目标提升到 macOS 26+（`XPCPeerRequirement` 全量可用）。
3. legacy `xpc_connection_*` 被正式标记废弃。
4. 出现只有 session 模型才能满足的需求（如 rich-error 驱动的重试语义成为硬需求）。

满足任一条时，按方案 B 启动 v3 架构设计。

## 附：探针产物

探针程序与迭代过程在本机 `/tmp/session-probe/main.swift`（未入库，本文档已含全部结论与
签名细节；关键签名另见 swiftinterface `arm64e-apple-macos.swiftinterface` L269–567）。
