# 双后端传输层重构模型（架构研究）

日期：2026-09-30 · 分支：`feat/dual-transport`（PR #10 基础上）· 研究范围：`main..HEAD`
全量 diff（+1786/−527）通读 + 交叉引用核查。所有代码级结论标注 `file:line`；运行时行为凡未探针
实跑的均显式标注 **未验证**。

前置文档：`Docs/XPCSessionMigrationFeasibility.md`（方案 B 决策依据）。本文不推翻该决策——
后端能力不对称（身份缺失、26 以下无 requirement、TERMINATION_IMMINENT 不可观测）是**事实约束**，
重构模型与约束共存而非否认。

## 结论

**传输缝（`XPCMessageChannel`）方向正确，但泛化只完成了三分之一条路径，且每一层用了不同的
统一方式。** 具体表现为三个结构性问题：

1. **泛化深度不一致**：actor system 主连接已通道化，但宿主层分叉成两套、客户端路径和 import
   路径仍硬编码 C 后端、测试协调器完全未迁移。后端选择权散落四处，没有单一配置点——
   "走哪个后端"是调用路径的副产物，不是声明式配置。
2. **同一概念有两套抽象**：acceptor 有协议（关联类型）+ 闭包盒两种统一方式；宿主有 C 专属 +
   session 专属两套；错误模型有三套（`ConnectionError` / `XPCChannelError` / `XPCRichError`
   启发式）；链式生命周期状态机写了三遍。
3. **缝的契约没缝住**：`XPCChannelError` 自称 backend-agnostic 但 C 一致性实现漏出原生
   `ConnectionError`；accepted-channel 的 activate 语义两后端相反；`.peerCodeSigningRequirement`
   case 在缝上不可达。

重构模型一句话：**一套通道缝、一个 acceptor、一套宿主、一个后端选择点、一套错误、一份生命周期
机械。** 允许破坏性变更（v0.x 阶段，README 尚未宣传 session 面）。

---

## 一、现状泛化深度矩阵

生产代码中每条通道路径的类型形态：

| 路径 | 形态 | 证据 |
|---|---|---|
| actor system 主连接 | `any XPCMessageChannel` ✅ | `XPCDistributedActorSystem.swift:45` |
| export 监听（服务端） | `XPCExportAcceptorBox` + 注入工厂，**默认 C** | `XPCDistributedActorSystem.swift:44,76-78` |
| import 拨号（客户端） | 硬编码 `XPCConnection.unmarshal` ❌ | `XPCActorReference.swift:39` |
| 客户端 root 连接 | 具体 `XPCConnection` ❌ | `XPCRootConnection.swift:76,121-149` |
| C 宿主 | 具体 `XPCConnection` ❌ | `XPCServiceHost.swift`（全文） |
| session 宿主 | `any XPCMessageChannel` ✅ | `XPCSessionServiceHost.swift` |
| 测试协调器 `xpcTest` | 具体 `XPCConnection`（8 处）❌ | `XPCRootTestCoordinator.swift` |
| 后端选择枚举 `XPCChannelTransport` | **生产零调用**，仅测试用 ❌ | `XPCTransport.swift:8-25` |

**后端选择的四个互不相识的决策点**：系统初始化的工厂默认值（C）、import 的硬编码（C）、
客户端的直接构造（C）、测试的枚举。没有任何一处配置能改变另一处。

---

## 二、冗余抽象

### R1 双 acceptor 抽象：协议 + 闭包盒并存

- `XPCChannelAcceptor`（关联类型协议，`XPCTransport.swift:122-136`）
- `XPCExportAcceptorBox`（闭包盒，`XPCTransport.swift:142-186`）

关联类型使协议无法直接作存在类型用于 actor 系统，于是又造了 Box；两个 acceptor 各写一个
`exportBox` 扩展把协议再擦回盒（`:166-186`）。生产代码只用 Box
（`XPCActorReference.swift:77,210`）；协议的泛型消费者只有测试，而测试在参数化入口仍 switch
具体类型构造（`XPCChannelTransportTests.swift:220-227`）。测试注释自称 "The listener level is
intentionally *not* unified behind a protocol"（`:31-33`）——实际上它统一了，用两种方式。
协议的关联类型带来的编译期通道类型特化，没有任何消费者使用。

### R2 C 后端双发送面 + 错误类型未归一

- 原生面：`send(message: XPCDictionary, replyQueue:) throws(ConnectionError)`
  （`XPCConnection.swift:302`）、`sendAndForget(message:)`（`:285`）。
- 通道面：`send(_ xpc_object_t, replyQueue:) async throws`（`XPCTransport.swift:317-321`）
  **直接转调原生面**——通过 `any XPCMessageChannel.send` 抛出的是 `ConnectionError`，
  不是 `XPCChannelError` 文档注释声称的 "backend-agnostic spelling"
  （`XPCTransport.swift:36-48` 与实现矛盾）。
- `XPCChannelError` 与 `ConnectionError` 三个 case 一一重复（`XPCTransport.swift:41-48` vs
  `XPCConnection.swift:276-283`）；`XPCChannelError.peerCodeSigningRequirement` 在缝上
  **不可达**（C 抛原生类型；session 的 send 只映射 interrupted/invalid，
  `XPCSessionChannel.swift:230`）。
- `applyPeerCodeSigningRequirement` 在 `XPCConnection` 上定义了两次，函数体相同：SwiftXPC
  公开版（`XPCTransport.swift:280-286`）与 DistributedXPC 内部版（`XPCRootActor.swift:247-256`）。

### R3 宿主层分叉而非泛化

`XPCServiceHost`（SwiftXPC，C 专属，功能全：requirement 安装→审计窗→拒绝管线
`didRejectPeer`→`cancel()`→`expectShutdown` 等待器→`eventLog`）vs
`XPCSessionServiceHost`（DistributedXPC，session 专属，贫化子集：无 `cancel`、无
`didRejectPeer`、无等待器、无 eventLog）。具体分叉：

- 同一套 bookkeeping（channels 字典 + shutdownRequested + completion）用**不同结构**写两遍
  （`XPCServiceHost.swift:188-206` vs `XPCSessionServiceHost.swift:39-42`）。
- session 宿主自己不驱动委托——委托分派被搬到 `xpcSessionMain` 里，用四个 Mutex 闭包槽
  （`onPeerDidEnd`/`onServiceWillShutdown`/`setShutdownCompletion`/`setPeerHandler`）拼装
  （`XPCSessionServiceHost.swift:85-98` + `154-187`）。C 宿主是委托直调。
- root 绑定 peerHandler 的 ~15 行逐行复制：`XPCRootActor.swift:119-141` vs
  `XPCSessionServiceHost.swift:131-146`（reserveRootID → setServiceShutdownHandler →
  `Root.shared` → guard root.id → clearRootReservation → bind，两者都落在同一个
  `XPCDistributedActorSystem.serviceHost` 单例上）。
- 模块归属相反：C 宿主在 SwiftXPC（actor-free）+ 绑定扩展在 DistributedXPC；session 宿主
  把管护与 actor 绑定（`serve`）混在同一类型且整体放在 DistributedXPC。

### R4 链式生命周期状态机三处重复

- `_ConnectionHandlerState`（`XPCConnection.swift:30-153`）：链式 handler +
  invalidation-once + disconnectionWaiters。
- `LifecycleBox`（`XPCSessionChannel.swift:39-91`）：链式 + invalidation-once，无 waiters。
- 宿主们的 Mutex 闭包槽（见 R3）。
- `AcceptHandlerBox`（Mutex 包闭包）在两个 acceptor 里各写一份
  （`XPCTransport.swift:204-206`、`XPCSessionChannel.swift:308-310`）。
- `waitForDisconnection` 只有 C 侧存在，通道协议没有。

### R5 两套 connect API，函数体重复

`XPCRootConnection.connect(toService:using:)`（`XPCRootConnection.swift:121-149`）与
`XPCRootActor.connect(toService:using:)`（`XPCRootActor.swift:219-245`）主体相同
（requirement → system → activate → resolve），一个多事件流与重试外壳。且
`XPCRootConnection.retrying` 只捕获 `XPCConnection.ConnectionError`（`:163`）——
连接是 session 通道时重试策略**静默失效**（session 错误不是 `ConnectionError`）。
重试缝与后端耦合。

### R6 已死/投机抽象

- `XPCChannelTransport.channel(dialing:)`：生产零调用（见矩阵）。它是为 import 路径设计的，
  但 import 硬编码了 C（`XPCActorReference.swift:39`）。要么升格为唯一拨号点（推荐，见模型
  §四.4），要么删除。
- `XPCChannelAcceptor` 协议本体（见 R1）。

### R7 杂项

- `XPCServiceHost.Session` 是零行为纯包装（`XPCServiceHost.swift:180-186`），与
  `PeerBox`（有取消语义，`XPCActorReference.swift:156-165`）同构不同命。
- session 侧无 `xpcTest` 对应物；端到端覆盖只有 1 个回声集成测试
  （`XPCSessionServiceHostTests.swift`），其 doc comment 仍写着 "Disabled:"——但全套件已无
  `.disabled` trait（已核实），注释是修复后遗留的文档腐化。
- README 完全未宣传 transport/session 面（本 PR 的 README diff 只有 raw-handle 一节）。

---

## 三、错位抽象（缝没缝住的地方）

### M1 accepted-channel 的 activate 契约两后端相反

C 侧交付的通道**必须 activate 才活**（`XPCTransport.swift:194-196`）；session 侧交付的通道
**已活**，activate 近似 no-op（`XPCSessionChannel.swift:122-126,152-153`）。协议文档自己承认
"the configuration/activation window are backend-specific"（`XPCTransport.swift:129-132`）。
统一协议存在的前提就是统一生命周期契约；这里没统一，消费者必须知道后端——抽象漏了。

### M2 错误模型三套并存且不互通

`ConnectionError` / `XPCChannelError` / Apple `XPCRichError.canRetry` 启发式映射
（`XPCSessionChannel.swift:206-213,230`）。`remoteCall` 直接透传后端错误
（`XPCDistributedActorSystem.swift:451,472`），客户端无法跨后端统一 catch。

### M3 后端选择无单一配置点

见矩阵与 §二.R6。这是当前架构的**核心缺陷**。

### M4 session 服务的 export 后端足迹不一致（偶然，非设计）

session 宿主上 export 的 actor 仍铸造 C 匿名监听（`makeExportAcceptor` 默认 C；
`XPCSessionServiceHost.swift:126-129` 注释承认 end-to-end session export 是 follow-up）。
跨后端互操作能跑（endpoint 无后端属性，参数化矩阵四组合已验证），但一个纯 session 服务进程
因此持有 C listener——行为对但理由错，重构后应变成"显式策略"。

### M5 回复语义手搓 + reply 无超时（通道层未解决的开放约束）

- C 一致性实现的 `reply`：create_reply + 手工合并 envelope 键 + remoteConnection 发送
  （`XPCTransport.swift:298-309`）；session 侧用原生 `payload.reply`
  （`XPCSessionChannel.swift:250-252`）。fire-and-forget 的回复被丢弃的规则两后端实现不同
  （C: create_reply 返回 nil；session: 静默消费——`XPCChannelTransportTests.swift:114-116`）。
- 拆会话根因**已定案并修复**（2026-09-28）：`sendAndForget` 曾误用 replyHandler 重载，注册了
  reply 期待而服务端 handler 返 nil，overlay 按文档拆整个 session；修复 = 改用无 reply 的
  throwing fire-and-forget 重载（`XPCSessionChannel.swift:196-200` 注释即此），回声测试现已
  启用且绿（其 "Disabled:" doc comment 是遗留腐化，见 R7）。C 侧的 create_reply 手搓合并是
  后端差异的真实代价，但语义已对齐。
- **真正的开放约束（探针已证，通道层未解）**：expectsReply 消息若永不被应答，客户端
  `send` **静默挂起、无超时**（Apple 不提供）——死对端 = 永久挂起的 continuation。
  `XPCMessageChannel.send` 目前无 reply 超时/取消语义，战略结论亦点名"需自建 reply 超时"。
  统一通道协议是落这个机制的正确位置（重构 §四.1 一并考虑）。

### M6 委托词汇表两套、默认实现习惯不同

`XPCServiceDelegate`：协议扩展全默认 + 闭包结构体 `XPCServiceConfiguration`。
`XPCSessionServiceDelegate`：无默认实现、空结构体当默认值
（`XPCSessionServiceHost.swift:27-34`）；`shouldAcceptPeer` 无身份可审计（后端无 pid/euid——
可行性研究已记录为约束）；拒绝路径完全不可观测（无 `didRejectPeer`，拒绝=静默 cancel）。
两套委托签名不同，服务代码不可跨后端移植。

### M7 缺失的 capability 查询（对齐可行性研究的 v3 设计）

可行性研究方案 B 明确列了 "identity capability 查询" 作为 Transport 协议要素；当前
`XPCMessageChannel` 没有 capability/身份面——C 后端的 pid/euid 被具体类型藏住，缝上不可见。
统一宿主要做审计窗就必须把它显式化（见模型 §四.3 的 `XPCPeerContext`）。

### 未验证事实清单（重构前探针，见 §四.8）

1. C 后端 activate 前 `sendAndForget` 的行为（缓冲 vs 误用陷阱）——session 侧未激活时**静默
   丢弃**（`XPCSessionChannel.swift:194`）。若 C 侧行为不同，同一 API 语义分叉。
2. session 通道 interruption 的可恢复性：C 匿名 listener-endpoint 通道在对端存活时会透明重拨
   （既有探针事实）；`XPCSession` 是否同样**未探**。`XPCChannelError.interrupted` 文档承诺
   "a later send may re-establish"（`XPCTransport.swift:44-45`），对 session 后端是未经证实
   的承诺。

---

## 四、重构模型

目标：**一套通道缝、一个 acceptor、一套宿主、一个后端选择点、一套错误、一份生命周期机械。**
所有条目允许破坏性变更；按依赖序编号。

### 1. 错误归一（先行，独立可做）

- `XPCMessageChannel.send/sendAndForget` 的错误统一为 `XPCChannelError`；C 一致性实现里做
  `ConnectionError → XPCChannelError` 映射，`.peerCodeSigningRequirement` 从此在缝上可达。
- `XPCConnection.ConnectionError` 改为 `XPCChannelError` 的 typealias（迁移期）或直接删除
  （破坏性，推荐——v0.x 且两类型 case 一一对应）。
- `remoteCall` 的错误面向客户端归一（DistributedXPC 错误包裹 `XPCChannelError`），
  `XPCRootConnection.retrying` 改捕获 `XPCChannelError`（顺带修复 session 下重试静默失效）。
- 删除 DistributedXPC 里重复的 `applyPeerCodeSigningRequirement` 内部版
  （`XPCRootActor.swift:247-256`）。

### 2. acceptor 单一化（先行，独立可做）

- 删除 `XPCChannelAcceptor` 协议；把 `XPCExportAcceptorBox` 升格为唯一 acceptor（改名如
  `XPCAcceptor`），**自己持有 handler 槽**（现在是注入闭包包住原生方法），两后端都构造它。
- 成员：`wireEndpoint` / `setAcceptHandler(any XPCMessageChannel)` / `activate()` /
  `cancel()`。`AcceptHandlerBox` 随之合并为一份。

### 3. 宿主合一（最大收益，依赖 §2）

- `XPCServiceHost` 泛化到 `any XPCMessageChannel`：
  - requirement 安装走通道的 `applyPeerCodeSigningRequirement`（session 后端已 fail-closed
    `ENOTSUP`——审计窗语义天然统一，拒绝照走 `didRejectPeer` 管线）；
  - 拒绝管线、`didRejectPeer`、`expectShutdown`、`eventLog` 全后端共享；
  - **唯一显式语义差异**（写进协议文档）：接受决定点——C 在宿主内激活前，session 在
    listener 回调内；宿主语义统一为"acceptor 交付待准入通道，宿主准入或拒绝"，session 侧
    拒绝=cancel 已活通道。
- 委托合一：`XPCServiceDelegate` 通道化，身份审计经 `XPCPeerContext` 值（C 后端带
  pid/euid/egid/asid，session 为 nil——补上 M7 的 capability 面）；协议扩展给默认实现，
  删掉空结构体默认值；`XPCSessionServiceConfiguration` 并入 `XPCServiceConfiguration`。
- 删除 `XPCSessionServiceHost` 与 `XPCSessionServiceDelegate`；root 绑定胶水
  （R3 的 15 行复制）合并为一份 `serve(rootType)`。
- `xpcSessionMain` 变薄入口：session acceptor + 同一宿主 + 同一 serve 胶水 + 同一委托。
  宿主整体搬回 SwiftXPC（与 C 宿主同模块，actor 绑定扩展留 DistributedXPC——修正 R3 的
  模块归属倒置）。

### 4. 后端选择单点化（依赖 §2）

- `XPCChannelTransport` 枚举保留但成为**唯一分发点**：进程级默认 + 显式覆盖。
  - `XPCExportableActor.unmarshal` 经它拨号（修 M3 硬编码）；拨号后端是本地策略，进程级默认
    合理（endpoint 本就不携带后端属性，跨后端互操作保留为显式能力）。
  - `makeExportAcceptor` 工厂从它派生（M4 的"session 服务铸造 C 监听"变成显式策略而非默认）。
  - `XPCRootConnection` 构造经它。
- 需要拍板的一个设计点：默认值取 C（兼容现状）还是"跟随宿主后端"。建议：显式参数 +
  进程级默认 = C（现状不变），文档写明跨后端互操作矩阵。

### 5. 客户端路径迁移（依赖 §1）

- `XPCRootConnection` 通道化（`connection: any XPCMessageChannel`），`XPCRootActor.connect`
  委托给它（消除 R5 重复）。
- `waitForDisconnection` 下沉进通道协议，两后端都能实现（session 侧 `LifecycleBox` 补 waiters，
  同时消除 R4 的功能不对称）。

### 6. 生命周期机械抽取（随时可做）

- 一份 `ChainedHandlers`（链式 + once + waiters）供两后端通道与宿主复用，替换
  `_ConnectionHandlerState`/`LifecycleBox`/宿主闭包槽三套实现。

### 7. 测试设施（依赖 §3）

- `xpcTest` 协调器通道化后，session 后端免费获得 in-process 测试设施（修 R7）；
- 宿主测试参数化到后端对（现在 C 宿主测试与 session 宿主测试是两套、后者禁用中）——统一后
  覆盖翻倍。

### 8. 前置探针（写代码前必须做，符合"探针验证"惯例）

1. **reply 超时语义**（M5 开放约束）：expectsReply 无应答 = 客户端永久挂起（探针已证 Apple 无
   超时）。设计通道层 `send` 的超时/取消参数——决定统一协议的 `send` 签名，应在错误归一
   （§1）时一并定形。
2. **C 后端激活前 send 行为**（M7 清单 1）：决定两后端的 pre-activation 语义是否需要显式
   契约（缓冲/丢弃/断言）。
3. **session interruption 可恢复性**（M7 清单 2）：决定 `XPCChannelError.interrupted` 的文档
   承诺是否对 session 成立，影响重试语义。

### 破坏性变更清单（汇总）

| 变更 | 条目 |
|---|---|
| 删 `XPCConnection.ConnectionError`（或 typealias） | §1 |
| 删 `XPCChannelAcceptor` 协议 | §2 |
| 删 `XPCSessionServiceHost` / `XPCSessionServiceDelegate` / `XPCSessionServiceConfiguration` | §3 |
| `XPCServiceDelegate` 签名通道化 + `XPCPeerContext` | §3 |
| `XPCRootConnection` / `XPCRootActor.connect` 签名通道化 | §5 |
| 删 `XPCConnection` 内部版 `applyPeerCodeSigningRequirement` | §1 |
| `makeExportAcceptor` 从 package 闭包变为 transport 派生 | §4 |

### 迁移顺序（依赖序）

```
探针(§8) → 错误归一(§1) ∥ acceptor 单一化(§2) ∥ 生命周期抽取(§6)
        → 宿主合一(§3)（依赖 §2）
        → 选择单点化(§4)（依赖 §2）→ 客户端迁移(§5)（依赖 §1）
        → 测试设施(§7)（依赖 §3）
```

每步独立可合、可回滚；§1/§2/§6 互不依赖可并行。预计净删除量：宿主第二实现（~190 行）、
重复状态机（~120 行）、Box 扩展与协议（~80 行）、connect 重复体（~30 行）。

---

## 五、实施记录

已确认决策（2026-09-30）：全量七步 + 文档；send 顺带实现 Swift 任务取消支持；进程级可写默认
`processDefault` + 显式参数。

### 探针结果（2026-09-30，/tmp/xpc-refactor-probes，本机实跑）

- **P1 C 后端激活前发送**（p1/p1b 两程序）：fire-and-forget 与 with-reply 均**不陷阱、缓冲**，
  activate 后投递 / 收到回复。
  → 通道统一契约定为 **"激活前发送缓冲，activate 后发出"**；session 后端补齐（改造前现状：
  fire-and-forget 静默丢弃、reply-send 抛 `.invalid`）。
- **P2 session 重拨能力**：listener 存活、服务端 cancel 已接受会话后——客户端 cancellation 收
  "Underlying connection interrupted"（**canRetry=false**）；同一 `XPCSession` 后续 send 全部
  throw（"Attempting to send message using a canceled session"）；listener 请求数保持 1。
  → **session 后端无透明重拨**：`XPCChannelError.interrupted` 的 "a later send may
  re-establish" 承诺仅对 C 后端成立；session 通道对端失联是终局（现行 `canRetry=false →
  invalidation 链`路由恰好正确）。`retrying` 在 session 后端上的重试是有限次的徒劳（保留、
  文档化）。
