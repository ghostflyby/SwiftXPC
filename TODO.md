# DistributedXPC TODO

目标：把当前 `DistributedXPC` 从"能编码出站调用的骨架"推进到"可用、可测的非泛型 distributed actor 系统"。

## 当前路线

当前阶段采用最简方案：

- 只支持非泛型 distributed method。
- 不在 request wire 上显式传 `returnType`、`errorType`、`genericSubstitutions`。
- 服务端不依赖反射恢复签名。
- 服务端通过 Swift runtime 的 `executeDistributedTarget` 分发：
  - key 是 compiler 生成的 `target.identifier`
  - 参数解码和实际调用交给 compiler 生成的 distributed accessor
- 静态表只作为 metadata registry：
  - key 是从 compiler 生成的 `target.identifier` 解析出的 Swift 方法名
  - value 当前只保存 typed-throws 的错误类型，用于客户端解码被擦除的业务错误
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
- [x] `DistributedXPC` 集成测试已补齐（in-process + 真实 connection pair 两条路径）。

## 代码复审发现的额外缺口

以下问题来自 2026-05-07 的完整代码复审，按优先级排列：

### P0 (崩溃 / 数据竞争风险)

- [x] `XPCConnection.set(context:)` 重复调用导致前一个 context 泄漏
  - `Sources/SwiftXPC/XPCConnection.swift:139-150`
  - `xpc_connection_set_context` 覆盖旧值但不会 release，`setFinalizerF` 也只对最后设置的值生效。
  - 如果 `set(context:)` 被调用两次，前一个 context 永远不会 release。

- [x] `XPCDictionary` 是 `@unchecked Sendable` 但内部可变
  - `Sources/SwiftXPC/XPCArray+XPCDictionary.swift:97-99`
  - `XPCDictionary` 的 `subscript` setter 修改了 `xpc_object` 指向的字典内容。
  - 若从多个并发 task 写入同一个 `XPCDictionary` 实例，存在数据竞争。
  - 当前调用链：macros encode 内部创建临时 `var dict = XPCDictionary()` 是安全的（栈上不逃逸），但公共 API 层面未做防护。

### P1 (行为错误 / 功能缺失)

- [x] `Array.unmarshal` 和 `Dictionary.unmarshal` 在元素解码失败时 crash
  - `Sources/SwiftXPC/XPCMarshal.swift:237` 和 `:260`
  - 使用 `try! Element.unmarshal(from: item)`，数组/字典中某个元素 marshal 失败时会触发运行时崩溃，而不是向上抛出错误。
  - 应该改用 `try ... catch { throw ... }` 或重新抛出一个聚合错误。

- [x] Demo 中 `DemoServiceSession` 对象泄漏
  - `Examples/DistributedXPCDemo/Sources/DemoService/main.swift:22`
  - 每次新连接追加到全局 `sessions` 数组，但断开的连接从不移除。
  - 长期运行的服务会累积已断开连接的 session 对象。

- [x] 无 connection 生命周期管理，actor 注册表泄漏
  - `Sources/DistributedXPC/Actor.swift:33-50`
  - `activeActorsLock` 中的 actor 在 connection 断开后永远不会被清理。
  - 应该有 `connection` invalidation handler 通知 actor system 清理。

### P2 (设计问题 / API 不完整)

- [ ] `XPCDictionary` 的 `subscript` set nil 语义与预期不符
  - `Sources/SwiftXPC/XPCArray+XPCDictionary.swift:133`
  - `dict["key"] = nil` 实际把 key 设为 XPC null，而不是删除 key。
  - 宏依赖这个行为对 optional 属性编解码，但对普通用户来说语义不直觉。

- [x] `try!` 在 `Array`/`Dictionary` unmarshal 实现中
  - `Sources/SwiftXPC/XPCMarshal.swift:237,260`
  - 见 P1 条目。

- [x] 没有 marshal 错误路径的测试
  - `Tests/SwiftXPCTests/` 中没有任何测试验证 `XPCMarshalError` 的正确抛出。
  - 例如：从错误的 XPC type 解码、缺失 key、越界、未知 enum case。

- [x] `Package.swift` 声明 iOS/macCatalyst 支持但 XPC 是 macOS 独占
  - `Package.swift:5`
  - `import XPC` 在 iOS/macCatalyst 上会编译失败。
  - 要么加 `#if os(macOS)` 条件编译，要么去掉虚假的平台声明。
  - 2026-09-05：已修复，`Package.swift` 现只声明 `.macOS(.v11)`。

- [x] `parseTargetIdentifier` 从右向左定位类名结束符 `C`，返回类型 mangling 含 `C` 时误解析
  - `Sources/DistributedXPC/XPCDispatch.swift`
  - 返回 class/actor 的 distributed method（如 `compose(...) -> IntegrationNote`，
    返回类型 mangling 为 `AA0C4Note`）中，`lastIndex(of: "C")` 会命中返回类型里的 `C`，
    把方法名解析成 `"Note()"`，导致服务端 metadata 查不到、客户端 fallback 失败，
    最终抛 `unsupportedThrownErrorType`。
  - 2026-09-05：已修复。改为从左到右扫描第一个合法的类名结束符，并跳过以大写开头的
    返回类型组件；新增 `ParseTargetIdentifier*` 回归测试。
  - 遗留：参数标签按 Swift 惯例假定小写开头，大写标签仍会被当作返回类型组件截断。

- [ ] 有标签/无标签 enum 的 wire layout 不一致
  - `Sources/SwiftXPCMacros/XPCMarshalMacro+Enum.swift`
  - 无标签 payload：`[caseName, val0, val1, ...]`（扁平在外层 array）
  - 有标签 payload：`[caseName, [labeled_payload]]`（嵌套子 array）
  - 这个不对称性给跨版本兼容带来隐患。

- [ ] `XPCConnection` 的 endpoint marshal 是一次性的
  - `Sources/SwiftXPC/XPCConnection.swift:182-190`
  - `xpc_endpoint_create` 创建的 endpoint 只能被 consume 一次。
  - 多次 `unmarshal` 同一个 marshaled data 会失败。

- [ ] `RemoteCallTarget: XPCMarshal` 的 availability 对齐有隐患
  - `Sources/DistributedXPC/Actor.swift:194-200`
  - 标注为 `@available(macOS 13.0, *)`，但 `distributed actor` 要求 macOS 15。

### P3 (风格 / 文档)

- [x] 测试中混用 `assert` 和 `#expect`
  - 旧测试（layout 测试）用 `assert(...)` 在 Release 中不生效。
  - 新测试（dispatch/reply）用 `#expect`。应该统一迁移到 `#expect`。
  - 2026-09-05：已统一迁移到 `#expect`。

- [x] `XPCActorID` 的 availability 与实际使用不一致
  - `Sources/DistributedXPC/Actor.swift:159`
  - 没有标注 `@available`，但在 `XPCDistributedActorSystem`（macOS 15+）中使用。
  - 建议统一标注。
  - 2026-09-05：已标注。

- [x] `@_spi(Experimental)` 覆盖核心 API
  - `Sources/DistributedXPC/XPCDispatch.swift`
  - `XPCDistributedTargetMetadataProviding`、`XPCDistributedTargetReturnKind`、`XPCDistributedTargetMetadata` 都是 `@_spi(Experimental)`。
  - 用户必须写 `@_spi(Experimental) import DistributedXPC` 才能使用。
  - 在完成 Phase 4 之前可以考虑保留，但在 Phase 6 前需要正式公开。
  - 2026-09-05：已从核心 API 移除 `@_spi(Experimental)`，`XPCDefaultActorInitializable` 等直接公开。

## Phase 1: 固定最小协议和测试骨架

目标：固定 v1 的最小协议，只支撑非泛型 distributed method。

- [x] 定义请求消息结构。
  - v1 只保留 `actorID`、`target`、`arguments`。
- [x] 定义 reply 消息结构。
  - 至少区分 `success(value)`、`successVoid`、`failure(error)`。
  - 错误编码策略先限定为 `XPCMarshal & Error`，必要时再补 `NSError` 兜底。
- [x] 约定协议版本字段。
- [x] 增加最小集成测试骨架。
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
- 新增的测试可以先占位，但用例名字和行为要先定下来。

## Phase 2: `executeDistributedTarget` 与服务端分发入口

目标：不依赖反射和显式 wire 类型元数据，使用 Swift runtime 的 distributed target accessor 执行调用，并保留 `target.identifier -> metadata` 的补充表。

- [x] 定义 actor 侧 metadata 协议。
- [x] 定义 target metadata 结构。
  - 当前只包含 `thrownErrorType`，用于恢复 Swift runtime 擦除后的 typed-throws 错误类型。
- [x] 为单个示例 distributed actor 手写一张最小 metadata 表。
- [x] 服务端新增统一入站 dispatch 入口。
  - 从 request 解出 `actorID`、`target`、`arguments`。
  - 找到本地 actor。
  - 使用 `executeDistributedTarget` 命中 compiler 生成的 distributed accessor。
- [x] 对找不到 actor、找不到 target、参数数量不匹配分别定义错误路径。

难点：

- `target.identifier` 只能做路由 key，不能承担"恢复类型"的职责。
- 类型关系必须由 compiler accessor 或 metadata 生成时静态写死，不能拖到运行时再猜。

完成标准：

- 一个示例 actor 能通过 `executeDistributedTarget` 完成一次真实分发。
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

- 不要让 reply message 的裸 payload 同时承担"成功值"和"错误对象"两种语义。
- 统一 envelope 后，客户端逻辑会简单很多。

完成标准：

- 成功返回值、`Void` 返回、业务错误、连接错误四条路径都可区分。

## Phase 4: 宏生成 metadata 表

目标：把手写 metadata 表替换为宏生成，减少样板代码，并为 reply 错误解码保留必要类型信息。

- [x] 设计一个 actor 级宏或辅助宏，为 distributed methods 生成静态 metadata 表。
  - 已落地为 `@XPCService` extension 宏（`Sources/SwiftXPCMacros/XPCServiceMacro.swift`）。
- [x] 生成稳定的 v1 target key。
  - 当前阶段只支持非泛型。
  - 当前阶段避免复杂重载。
  - v1 wire 仍携带 compiler 生成的 `target.identifier` 供 Swift runtime 执行；metadata key
    使用 `parseTargetIdentifier` 解析出的 Swift 方法名。
- [x] 让宏直接展开 metadata。
  - 参数数量、返回形态、必要时的错误类型在展开代码中静态写死。
  - 当前 metadata 只保留 `thrownErrorType`。
- [x] 用宏替换示例 actor 的手写 metadata 表。
  - 测试 fixture 与 `DemoGreeter` 均已改用 `@XPCService`。

难点：

- 宏应生成"compiler target identifier -> metadata"的静态对应关系，而不是生成"字符串 -> 类型反查"逻辑。
- 如果要支持重载，需要先定义稳定 key 规则。

完成标准：

- 示例 actor 不再手写 metadata 表，但行为与手写版本一致。

## Phase 5: 集成测试补齐

目标：让后续重构有安全网。

- [x] 新增 `DistributedXPC` 端到端测试。
  - `Tests/SwiftXPCTests/DistributedXPCIntegrationTests.swift`，覆盖 in-process 与
    `xpc_endpoint_create` 真实 connection pair 两条路径。
- [x] 覆盖以下场景：
  - 成功返回值
  - `Void` 返回
  - actor 方法抛错
  - 参数解码失败（dispatch 级 + 端到端 raw wire）
  - 未知 actor ID（dispatch 级 + 端到端错误 envelope 回传）
  - 未知 target（dispatch 级 + 端到端错误 envelope 回传）
  - connection interrupted / invalid（send 报错 + actor 注册表清理）
  - 多参数与嵌套 `XPCMarshal` 类型（`compose(note:greeting:times:)` round-trip）
  - 并发调用（20 路并发 greet）
- [x] 增加协议 round-trip 测试。
  - request 编码/解码
  - reply 编码/解码

完成标准：

- `swift test` 中出现真正的 `DistributedXPC` 测试，而不是只有 `SwiftXPC` 序列化测试。

## Phase 6: 健壮性与工程化

目标：把"能跑"推进到"能维护"。

- [x] 修复 `XPCConnection.set(context:)` 重复调用的 memory leak。
- [x] 评估 `XPCDictionary` 的 `Sendable` 安全性。
- [x] 修复 `Array.unmarshal` / `Dictionary.unmarshal` 中 `try!` 导致的崩溃风险。
- [x] 修复 Demo 中 `DemoServiceSession` 泄漏。
- [x] 添加 connection 生命周期管理，连接断开时清理 actor 注册表。
- [ ] 为公共错误定义稳定错误类型，而不是散落 `fatalError`。
- [ ] 清理当前占位实现和未使用类型。
- [ ] 明确线程模型和执行队列。
- [ ] 明确取消、超时、连接中断的处理策略。
- [ ] 评估是否需要服务端鉴权/entitlement 校验接入点。
- [ ] 评估 `XPCDictionary` subscript set nil 语义是否应该改为删除 key。
- [x] 为 `Float` 添加 `XPCMarshal` 实现。
- [x] 统一测试中的 `assert` 为 `#expect`。
- [x] 对齐 `XPCActorID` 的 `@available` 标注与实际使用场景。
- [x] 评估是否在 Phase 6 结束时取消 `@_spi(Experimental)`。
  - 2026-09-05：已提前移除，核心 API 直接公开。
- [ ] 补充 README 或示例。

## 下一阶段：根 Actor 与 Actor 引用

当前基础 RPC 已闭环，但公开 API 尚未解决两个问题：客户端如何获得第一个服务端 actor，
以及 distributed actor 如何作为参数或返回值跨进程传递。

### 已形成的方向

- 一个 actor proxy 对应一条独立 XPC connection/channel，而不是在同一 connection 上用全局
  `actorID` 复用多个 actor。
- 服务需要一个根 actor 作为 bootstrap 入口。客户端连接服务后，先获得根 actor proxy，再由
  根 actor 的 distributed methods 创建或返回用户 actor。
- 根 actor 不应被框架固定成包含所有业务 factory 的具体类型。框架应定义最小根 actor 契约，
  允许用户提供自己的 distributed actor 作为根，并注册到 listener/service。
- 使用 `XPCDistributedActorSystem` 的 distributed actor 应通过宏自动获得真正的 `XPCMarshal`
  一致性，不要求用户编写序列化扩展。
- actor reference 的 wire payload 至少包含新建的 XPC endpoint 和 actor ID（必要时再附加版本与
  actor 类型标识）。endpoint 使 `static unmarshal(from:)` 自包含：接收端从 endpoint 创建新的
  `XPCConnection` 和 `XPCDistributedActorSystem`，再以 payload 中的 ID 解析对应 actor proxy。
- actor 的 `marshal()` 负责为本地 actor 导出一条匿名 listener/channel，并由原 actor system 持有
  export session；新 channel 只路由到被导出的这个 actor。
- Swift 自带的 distributed actor `Codable`（通过 `decoder.userInfo[.actorSystemKey]` 注入 system）
  可作为实现参考，但当前 endpoint 自包含模型不需要把 actor 解码上下文偷渡到普通值 codec。
- v1 可以先只允许导出本地 actor；将已经是 remote proxy 的 actor 再转发给第三方需要源端重新
  mint endpoint 或增加 relay 协议，应单独设计。

### 待决设计

- 根 actor 契约使用 marker protocol、带静态 factory 的协议，还是 listener 初始化时的泛型参数。
- 根 actor 是否固定使用约定 ID，还是 listener 在 bootstrap reply 中返回 actor reference endpoint。
- 每次传递同一 actor 是新建独立 channel，还是复用已有 channel；复用时如何管理生命周期和并发。
- actor reference 是否需要 wire-level 类型标识。静态方法签名已知具体 actor 类型时可以只传 endpoint；
  existential actor 或未来跨版本场景可能需要稳定标识。
- endpoint 创建失败、连接失效、actor 已释放、错误 actor 类型的稳定错误语义。
- connection/channel 的所有权：proxy 释放时是否 cancel，服务端何时 resign actor，循环 actor 引用如何处理。
- 自动一致性由编译器/runtime 能力、宏生成，还是内部 actor-reference wrapper 完成。不能要求用户手写
  `XPCMarshal.unmarshal`，因为该 API 没有解析 actor proxy 所需的 actor-system 上下文。

### 建议先完成的验证

- 最小 root bootstrap 原型：用户根 actor 注册、客户端获得根 proxy、根方法返回一个用户 actor。
- actor 作为返回值的端到端测试，确认 endpoint transfer、proxy resolve 和 connection 生命周期。
- actor 作为参数的反向端到端测试，确认接收端能调用传入 actor（callback 场景）。
- 同一 actor 多次传递、channel invalidation、proxy 释放和服务端 actor 注销测试。
- 原型稳定后再决定是否公开通用 `XPCMarshal` 一致性，避免把 actor-specific 上下文泄露到普通值协议。

## 推荐执行顺序

1. Phase 1-5：基础 RPC、metadata 宏和集成测试（已完成）。
2. 根 actor bootstrap：用户根 actor 注册、客户端获得真实远端根 proxy。
3. Actor reference：actor 返回值、actor 参数、独立 endpoint/channel 和生命周期。
4. Phase 6：稳定错误、线程模型、取消/超时、中断和鉴权。
5. Wire 收尾：版本校验、enum layout、nil 语义、availability 与兼容策略。
6. 文档与示例：让 DemoApp 通过根 actor 完成真实跨进程调用。

## 已完成的基础 RPC 里程碑

以下范围已经完成：

- [x] 单 service、单 connection。
- [x] 非泛型 distributed method。
- [x] 参数和返回值都要求 `XPCMarshal`。
- [x] 支持普通返回值、`Void`、`XPCMarshal & Error`。
- [x] 服务端通过 `executeDistributedTarget` 分发，不依赖反射恢复签名。
- [x] 端到端测试覆盖成功、`Void`、抛错和协议错误路径。

## 当前可用 API 里程碑

完成以下范围后，外部客户端才有稳定、明确的服务入口：

- [ ] 用户 distributed actor 可注册为根 actor。
- [ ] 客户端可从 Mach service connection 获得该根 actor 的远端 proxy。
- [ ] 根 actor 可返回用户 actor，并为其建立独立 XPC endpoint/channel。
- [ ] 用户 actor 可作为 distributed method 参数传回另一端（callback）。
- [ ] DemoApp 不再本地构造 `DemoGreeter`，而是通过根 actor 完成真实跨进程调用。
- [ ] 覆盖根 channel、子 actor channel、invalidation 和释放生命周期的端到端测试。

基础 RPC 里程碑证明了 compiler accessor 与 XPC wire 可以闭环；下一步优先固定 bootstrap 和
actor-reference 语义，再扩展泛型、复杂重载或跨版本类型协商。

---

> **复审说明**: 2026-05-07 对全部源码进行了完整复审（覆盖 SwiftXPC、SwiftXPCMacros、DistributedXPC 三个模块和测试）。新增的 `P0-P3` 节来自本次复审发现。GPT-5.5 的 Moon Bridge 通道不可用（503），复审由 deepseek-v4-flash 完成。
>
> **2026-09-05 进度同步**: 勾选状态与代码实际进度对齐（Phase 4 宏已落地、Phase 5 集成测试补齐、Package.swift 平台与 `@_spi(Experimental)` 清理）。补齐 Phase 5 剩余测试场景时发现并修复了 `parseTargetIdentifier` 对含 `C` 返回类型 mangled name 的误解析（见 P2 节）。
