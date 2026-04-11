# DistributedXPC TODO

目标：把当前 `DistributedXPC` 从“能编码出站调用的骨架”推进到“可用、可测的非泛型 distributed actor 系统”。

## 当前路线

当前阶段采用最简方案：

- 只支持非泛型 distributed method。
- 不在 request wire 上显式传 `returnType`、`errorType`、`genericSubstitutions`。
- 服务端不依赖反射恢复签名。
- 服务端通过静态分发表分发：
  - key 是 `target.identifier`
  - value 是宏或手写生成的 typed handler
- reply wire 只区分：
  - `returnValue`
  - `returnVoid`
  - `throwError`

当前阶段明确不做：

- 泛型 distributed method
- 依赖 wire 显式传类型元数据的通用协议设计
- 通过字符串反查 Swift 类型
- 面向跨版本/异构编译产物的协议兼容设计

## 现状

- [x] `XPCMarshal` 基础序列化可用，已有 round-trip 和 layout 测试。
- [x] `XPCDistributedActorSystem` 已有 `ActorID` 分配、本地 actor 注册、出站 `remoteCall` 骨架。
- [x] request/reply 基础 envelope 已补齐，并有 round-trip 测试。
- [x] 入站消息分发已接入 actor system 初始化路径。
- [x] reply/result/error 协议已通过统一 envelope 闭环。
- [x] `remoteCallVoid` 已实现 reply envelope 解码。
- [ ] 没有 `DistributedXPC` 集成测试。

## Phase 1: 固定最小协议和测试骨架

目标：固定 v1 的最小协议，只支撑非泛型 distributed method。

- [x] 定义请求消息结构。
  - v1 只保留 `actorID`、`target`、`arguments`。
- [x] 定义 reply 消息结构。
  - 至少区分 `success(value)`、`successVoid`、`failure(error)`。
  - 错误编码策略先限定为 `XPCMarshal & Error`，必要时再补 `NSError` 兜底。
- [x] 约定协议版本字段。
- [ ] 增加最小集成测试骨架。
  - 一个本地服务端 actor。
  - 一个客户端 actor proxy。
  - 一条成功调用路径。
  - 一条 `Void` 返回路径。
  - 一条抛错路径。

涉及文件：

- `Sources/DistributedXPC/Actor.swift`
- `Sources/DistributedXPC/XPCInvocationEncoder.swift`
- `Sources/DistributedXPC/XPCInvocationDecoder.swift`
- `Tests/SwiftXPCTests/`

完成标准：

- 能明确写出 request/reply 的字段表。
- request 不再携带显式类型元数据。
- 新增的测试可以先 `TODO`/`XCTExpectFailure` 占位，但用例名字和行为要先定下来。

## Phase 2: 静态分发表与服务端分发入口

目标：不依赖反射和显式类型元数据，建立 `target.identifier -> typed handler` 的分发机制。

- [x] 定义 actor 侧分发协议。
  - 例如 `AnyXPCDistributedDispatching`。
- [x] 定义类型擦除的 handler 结构。
  - handler 内部静态写死参数解码、方法调用、reply 编码。
- [x] 为单个示例 distributed actor 手写一张最小分发表。
- [x] 服务端新增统一入站 dispatch 入口。
  - 从 request 解出 `actorID`、`target`、`arguments`。
  - 找到本地 actor。
  - 将 actor 转为可分发协议并命中 handler。
- [x] 对找不到 actor、找不到 target、参数解码失败分别定义错误路径。

难点：

- `target.identifier` 只能做路由 key，不能承担“恢复类型”的职责。
- 类型关系必须在 handler 生成时就静态写死，不能拖到运行时再猜。

完成标准：

- 一个示例 actor 能通过静态表完成一次真实分发。
- 系统层不需要从字符串恢复参数/返回/错误类型。

## Phase 3: 闭环返回值、`Void` 和错误

目标：把 request/reply 做成真正的 RPC，而不是只完成 happy path。

- [x] 实现 `XPCInvocationResultHandler.onReturn(value:)` 的返回值编码。
- [x] 实现 `XPCInvocationResultHandler.onReturnVoid()` 的空返回编码。
- [x] 实现 `XPCInvocationResultHandler.onThrow(error:)` 的错误编码。
- [x] 调整客户端 `remoteCall` 解码 reply envelope，而不是直接把 reply 当成 `Res`。
- [x] 实现 `remoteCallVoid`。
- [x] 清理或重构现有 `XPCReply`，避免 dead code。

建议：

- 不要让 reply message 的裸 payload 同时承担“成功值”和“错误对象”两种语义。
- 统一 envelope 后，客户端逻辑会简单很多。

完成标准：

- 成功返回值、`Void` 返回、业务错误、连接错误四条路径都可区分。

## Phase 4: 宏生成分发表

目标：把手写分发表替换为宏生成，减少样板代码。

- [ ] 设计一个 actor 级宏或辅助宏，为 distributed methods 生成静态 handler 表。
- [ ] 生成稳定的 v1 target key。
  - 当前阶段只支持非泛型。
  - 当前阶段避免复杂重载。
- [ ] 让宏直接展开 typed handler。
  - 参数类型、返回类型、错误类型在展开代码中静态写死。
- [ ] 用宏替换示例 actor 的手写分发表。

难点：

- 宏应生成“字符串 -> typed handler”的静态对应关系，而不是生成“字符串 -> 类型反查”逻辑。
- 如果要支持重载，需要先定义稳定 key 规则。

完成标准：

- 示例 actor 不再手写 dispatch 表，但行为与手写版本一致。

## Phase 5: 集成测试补齐

目标：让后续重构有安全网。

- [ ] 新增 `DistributedXPC` 端到端测试。
- [ ] 覆盖以下场景：
  - 成功返回值
  - `Void` 返回
  - actor 方法抛错
  - 参数解码失败
  - 未知 actor ID
  - 未知 target
  - connection interrupted / invalid
  - 多参数与嵌套 `XPCMarshal` 类型
  - 并发调用
- [x] 增加协议 round-trip 测试。
  - request 编码/解码
  - reply 编码/解码

完成标准：

- `swift test` 中出现真正的 `DistributedXPC` 测试，而不是只有 `SwiftXPC` 序列化测试。

## Phase 6: 健壮性与工程化

目标：把“能跑”推进到“能维护”。

- [ ] 为公共错误定义稳定错误类型，而不是散落 `fatalError`。
- [ ] 清理当前占位实现和未使用类型。
- [ ] 明确线程模型和执行队列。
- [ ] 明确取消、超时、连接中断的处理策略。
- [ ] 评估是否需要服务端鉴权/entitlement 校验接入点。
- [ ] 补充 README 或示例。

## 推荐执行顺序

1. Phase 1：固定最小协议和测试骨架。
2. Phase 2：用手写静态分发表打通第一次分发。
3. Phase 3：补 reply/void/error 闭环。
4. Phase 4：把分发表宏化。
5. Phase 5：补足集成测试。
6. Phase 6：做健壮性和文档收尾。

## 当前最小可交付里程碑

若目标是尽快拿到第一个“真的能用”的版本，建议先做到以下范围：

- [ ] 单 service、单 connection。
- [x] 非泛型 distributed method。
- [x] 参数和返回值都要求 `XPCMarshal`。
- [x] 支持普通返回值、`Void`、`XPCMarshal & Error`。
- [x] 服务端通过静态分发表分发，不依赖反射恢复签名。
- [ ] 端到端测试覆盖 1 条成功路径、1 条 `Void` 路径、1 条抛错路径。

做到这里，再继续扩展泛型、复杂重载、类型元数据协商，风险会低很多。
