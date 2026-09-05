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
  - key 是 `target.identifier`
  - value 是参数数量、返回形态、必要时的错误类型等补充元数据
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
  - 当前包含 `argumentCount`、`returnKind`、`returnType`、`thrownErrorType`。
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
  - v1 key 使用 compiler 生成的 mangled target identifier，客户端由 `parseTargetIdentifier` 解析为方法名。
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

## 推荐执行顺序

1. Phase 1：固定最小协议和测试骨架。
2. Phase 2：用 `executeDistributedTarget` 打通第一次分发，并保留 metadata 表。
3. Phase 3：补 reply/void/error 闭环。
4. Phase 4：把 metadata 表宏化。
5. Phase 5：补足集成测试。
6. Phase 6：做健壮性和文档收尾。

## 当前最小可交付里程碑

若目标是尽快拿到第一个"真的能用"的版本，建议先做到以下范围：

- [x] 单 service、单 connection。
- [x] 非泛型 distributed method。
- [x] 参数和返回值都要求 `XPCMarshal`。
- [x] 支持普通返回值、`Void`、`XPCMarshal & Error`。
- [x] 服务端通过 `executeDistributedTarget` 分发，不依赖反射恢复签名。
- [x] 端到端测试覆盖 1 条成功路径、1 条 `Void` 路径、1 条抛错路径。

做到这里，再继续扩展泛型、复杂重载、类型元数据协商，风险会低很多。

---

> **复审说明**: 2026-05-07 对全部源码进行了完整复审（覆盖 SwiftXPC、SwiftXPCMacros、DistributedXPC 三个模块和测试）。新增的 `P0-P3` 节来自本次复审发现。GPT-5.5 的 Moon Bridge 通道不可用（503），复审由 deepseek-v4-flash 完成。
>
> **2026-09-05 进度同步**: 勾选状态与代码实际进度对齐（Phase 4 宏已落地、Phase 5 集成测试补齐、Package.swift 平台与 `@_spi(Experimental)` 清理）。补齐 Phase 5 剩余测试场景时发现并修复了 `parseTargetIdentifier` 对含 `C` 返回类型 mangled name 的误解析（见 P2 节）。
