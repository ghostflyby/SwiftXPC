# PR #10 架构复审与重设计

复审基线：`31ee515`（PR #10 原始 HEAD）。本次允许破坏性 API 变更；以下描述当前工作树的设计。

## 复审结论

原 PR 统一了两种后端的表面接口，但仍让上层依赖后端类型、全局配置和不同的生命周期规则。
关键问题已经在此次重设计中处理。阻塞派发与私有 actor 解析属于此前已有的问题，
并非本 PR 新引入：

| 优先级 | 原实现与触发条件 | 影响与修复 |
|---|---|---|
| P1 | `XPCSessionChannel` 用两个锁分别管理 incoming handler 和 pending messages；安装 handler 可以发生在 receive 检查之后、append 之前 | 消息留在缓冲区而没有后续 flush。改为一份 inbox 状态、逻辑激活门控和串行 drain |
| P1 | Session 还未创建时调用 cancel，只取消非空 native session | 没有 invalidation，`waitForDisconnection` 永久等待。取消在所有阶段都结束本地生命周期 |
| P1 | Session 取消时只完成激活前的 pending sends | 已发出请求的 continuation 依赖 native reply；未回复的请求可能继续等待。显式跟踪并结束全部 in-flight sends |
| P1 | accept callback 内把交付任务发到 global queue | 任务可能先于 callback 返回，用户发送会触发 native API misuse。交付排到 listener 的同一串行 target queue |
| P1 | Session listener 在 deinit 中永久 `passRetained` | 每个 export listener 都泄漏。实跑确认 inactive listener 的 cancel/dispose 顺序触发 `_xpc_connection_last_xref_cancel`；取消时先完成激活要求，再正常释放 |
| P1 | `XPCSendSink.finish` 在 install 之前允许覆盖已存 outcome | 取消和回复竞争时，后来的结果覆盖先到结果。首次 outcome 一经提交就不可覆盖 |
| P1 | Session endpoint factory 直接构造 `XPCEndpoint` | 非 endpoint 输入可能触发 overlay precondition。两后端在工厂边界都抛 `XPCMarshalError` |
| P1 | actor dispatch 用 semaphore 等待 async 方法结束 | 悬挂调用会堵住 XPC event queue，妨碍 invalidation 和关闭。改为每通道一条有序 Task 链 |
| P1 | 私有 actor 的 mangled name 含哈希 `…C03F0B…` | 方法名启发式解析误得 `F0B()`。用 actor metadata 验证候选，继续扫描真实方法名 |
| P2 | `XPCIncomingMessage` 声称只能回复一次但未实施 | 复制 message 后仍可重复回复。共享一次性 capability，重复回复忽略 |
| P2 | root system 为维持进程全局 singleton 创建闲置 C connection，且逐 peer 修改 export transport | 注册表生命周期与 transport 耦合；服务实例相互干扰。root 和 registry 由具体服务实例持有，transport 构造时确定 |
| P2 | actor import 读取可变 `processDefault`；`connect(using:)` 不从 channel 推导系统 transport | Session root 的子引用可能悄悄切换到 C；测试并发修改策略会互相影响。嵌套解码继承调用 system 的 transport，独立导入可显式指定 |
| P2 | `retrying` 同时重试 invalid 和 session 错误；resolve 后立即发 connected | 终局错误被无效重试，本地代理创建被当作已连接。只重试 C interruption；初始事件改为 ready |

## 职责与依赖

```mermaid
flowchart TD
  Entry["xpcMain / xpcSessionMain / xpcTest"] --> Service["XPCActorService: root + registry"]
  Service --> Host["XPCServiceHost: 绑定与关闭"]
  Service --> System["XPCDistributedActorSystem: actor identity / invocation / export"]
  Listener["XPCChannelAcceptor: native 准入与接收通道"] --> Host
  Host --> Channel["XPCChannel: 生命周期与消息"]
  System --> Channel
  System --> Marshal["XPCMarshal: wire 编解码"]
  Channel --> C["XPCConnection: C native interop"]
  Channel --> Session["内部 XPCSession adapter"]
  Macros["SwiftXPCMacros: 编译期展开"] --> Marshal
```

| 层 | 负责 | 边界 |
|---|---|---|
| 序列化 | `XPCMarshal` 和宏；原始 XPC payload / wire envelope | 业务载荷布局独立于连接与宿主；取消回复扩展使 wire version 升至 2 |
| transport | `XPCChannel`、`XPCChannelTransport`、`XPCChannelAcceptor` | 一个具体 owned channel；后端只在内部 enum 中分派，不开放需要猜测能力的 existential 协议 |
| 服务绑定 | `XPCServiceHost` 与 `XPCServiceDelegate` | 绑定已准入 channel、peer bookkeeping、shutdown；native audit 由 acceptor 与 C/Session 专用协议处理 |
| actor runtime | `XPCDistributedActorSystem` | 本地 registry 不需要 outbound channel；代理 system 从 channel 取得 transport；负责 dispatch / export / import |
| 服务组装 | `XPCActorService<Root>` | 每实例一个 root、一个 local system、一个 host；root factory 支持依赖注入 |
| 入口与测试 | `xpcMain`、`xpcSessionMain`、`xpcTest` | 选择 listener 与进程退出策略；测试只增加 watchdog、事件等待和模拟断连 |

`XPCConnection` 保留为 C 专属低层 API。通用通道不再复制 optional 身份或 no-op interruption /
requirement 接口；accepted 身份快照保留在 native connection。C 与 Session 两个 Delegate 协议继承
共同服务通知，通过专用构造入口在编译期选择后端，没有 runtime downcast。

服务 delegate 不要求 `init()`；actor 服务使用带 Root 关联类型的生命周期协议及两个 native 专用子协议。
`XPCApp` 已删除，两个专用 delegate 提供默认 static main，具体类型直接标注 `@main`；入口使用 init() 构造 delegate，Session 声明 static serviceName。阶段顺序以 source DocC 为准。
完整公开 API 的逐面审计、替代方案、收拢决定与迁移见 [PublicAPIAudit.md](PublicAPIAudit.md)。

## 生命周期契约

- channel 的逻辑状态是 inactive → active → invalid，cancel 可在任何状态调用；activate 幂等。
- 两种 acceptor 都交付需要逻辑 activate 的 channel。Session 在 native callback 返回后已由系统激活，
  但库层在服务绑定完成前缓冲 incoming messages，避免 handler 安装与交付竞争。
- acceptor 状态锁只决定原生操作的执行方，`activate/cancel` 均在锁外执行；取消与激活重叠时，
  先停止新的 callback claim，再由激活调用完成原生取消，避免取消先于激活或重复激活。
  已 claim 的回调可在取消返回后结束，关闭 host 会拒绝其迟到绑定；重叠 activate 抛 inProgress。
- dialed Session 的创建、handler 安装和原生激活在 control lock 外执行；activating 状态
  唯一指定执行方。并发 cancel 立即终止库层通道、释放发送等待者，由激活方完成原生取消。
- Session 替换或取消 incoming handler 时，锁内取走旧 closure，锁外释放，允许 captures 析构重入 cancel。
- host 的取消/关闭状态与 shutdown waiters 由同一把锁维护；bare cancel 原子地取走自己的
  waiters；bare cancel 是终局，后来 shutdown request 不运行管线。恢复 continuation 与取消 peer 均在锁外。
- listener 的 Session handler 配置仍在 accept callback 内完成；交付排到同一 target queue，确保
  native decision 已返回。[Apple 的 accept 文档](https://developer.apple.com/documentation/xpc/xpclistener/incomingsessionrequest/accept(incomingmessagehandler:cancellationhandler:)-48c3k)
  明确返回的 inactive session 是用于这个配置窗口。
- 激活前发送缓冲。Session 的 enqueue 与激活 flush 使用同一 control lock 决定顺序，再到 serial
  send queue 执行，避免后发消息越过激活前消息。
- 取消 awaiting task 结束自己的 continuation，不撤回已经提交给 peer 的请求；channel 仍可使用。
  取消 channel 则结束整个 channel，Session 的全部 in-flight sends 也立即失败。
- invalidation 一次投递并释放 handler captures；晚注册 handler 立即补发。C interruption 可以重复；
  Session 的所有 peer loss 均是 terminal invalidation；native send 错误也采用 fail-stop 策略，
  不将 XPCRichError 的描述猜测为 C 的 signing/interruption code。
- host 先注册 peer，再安装带 replay 的 invalidation handler；不在 host state lock 内激活 channel，
  避免同步 invalidation 重入死锁。handler 保留 channel 至事件交付，终局事件清除这条引用链。
- actor invocations 按通道 FIFO 执行，等待异步方法时不阻塞 transport 回调队列。此顺序仍是严格的：
  业务代码若等待同一通道排在自身后面的 invocation，会形成业务层循环等待。

## root、导入策略与所有权

root 是 **每个服务实例一次构造**，所有接受的 root peers 绑定同一个 actor。不同服务实例可以在
同一进程内各自拥有 `.root`，因为 identity 的命名空间是各自的 system。生产和测试使用同一组装路径。

`XPCActorService(delegate)` 在构造时保留 root identity，调用 factory 后校验 root 及所属 system。
`cancel()` 结束自己创建的 listeners、peers 和 export sessions，并释放 registry pins。peer 断开不会结束整个服务，也不会
使别的客户端或已导出的子 actor 失效。

system 的 transport 构造后不可变。返回值中的引用在 reply decoding 范围继承客户端 system 的策略；
参数中的引用在服务端 argument decoding 范围继承服务端 system 的策略。Task-local 解码上下文仅覆盖
解码操作及其嵌套 `XPCMarshal`，没有可变进程默认值。独立调用：

```swift
let actor = try Worker.unmarshal(from: payload, transport: .session)
```

协议要求的 `unmarshal(from:)` 在上述 runtime 范围之外使用固定 C 默认值。endpoint 本身仍支持
跨后端互操作；本地选择不写进 wire。

`XPCChannel` 是拥有资源的引用类型，最后一个 channel 引用销毁时取消 native channel。
actor system 保留所用的 channel，省去 `ownsConnection` / `allowsChildReclamation` 配置组合。
本地 registry 在 export peers 全部 drain 后尝试释放子 actor 的 pin；root 保留至 service 结束。

## 破坏性迁移

| 旧 API | 新 API |
|---|---|
| `any XPCMessageChannel` | `XPCChannel` |
| 公共 `XPCSessionChannel(...)` | `XPCChannelTransport.session.channel(...)` |
| delegate 的 `XPCPeerContext` | 生命周期使用 `XPCChannel`；准入使用 native connection / request |
| `peer.channel` | `peer` |
| transport 上的 `processDefault` | 显式 transport；runtime 嵌套引用自动继承 |
| `XPCRootActor.shared` / `XPCDistributedActorSystem.serviceHost` | `XPCActorService.root` / `.root.actorSystem` |
| `XPCServiceHost(rootType, delegate)` | `XPCActorService(rootType, delegate).host`；必须保留 service |
| 用 idle connection 创建本地 system | `XPCDistributedActorSystem(transport:)` |
| `system.connection` 永远非空 | 代理 system 非空；本地 registry 为 nil |
| channel `send(payload, replyQueue:)` | `send(payload)`；native C API 仍支持 reply queue |
| `XPCRootConnectionEvent.connected` | `.ready`：本地代理就绪，首次调用才建立通信 |
| `XPCServiceDelegate.main()` / `XPCApp` | 两个专用 typed delegate 的默认 static main；直接标注 @main |
| 对 invalid / session 错误重试 | 仅 C `.interrupted` 重试 |

C 的字符串 requirement 留在 native connection 专用 API。Session 的 native request 在 accept
之前审核；不再先原生 accept 再用 cancel 模拟拒绝。macOS 26 named Listener 的 typed requirement
使用 Session 专用 constructor，不混入通用 channel。库内 actor service.listen 负责完整监听器组装
及所有权；routing / shutdown cleanup 在构造时固定，不能被 setter 替换。

## 验证

验证覆盖原有布局、宏、dispatch、actor reference、forwarding、peer audit、root recovery 和关闭测试，
以及四种 server/client backend 组合。新增回归覆盖：

- 未激活 channel/listener 取消、缓冲 reply 结束和断连等待；
- C / Session acceptor 并发激活与取消，验证取消终局与原生释放顺序；
- 取消早于 continuation 安装时的首次结果保证；
- message 多个副本的并发一次性回复；
- 非法 endpoint 在两后端都抛错误；
- 私有 actor 哈希干扰方法解析；
- 悬挂 invocation 时 peer invalidation 与本地 in-flight send 结束；
- 多个服务实例 registry 隔离及同一服务 root 共享；
- Session 子引用继承 backend 和终局错误不重试；
- C/C、Session/Session 两种 actor proxy forwarding 与并发 re-export；
- Session 激活同步取消/重入、激活期间并发取消及创建失败；
- bare cancel 后显式 shutdown 的等待语义及 shutdown 管线期间并发 cancel。

最终验证已通过：

- `SWIFTXPC_WARNINGS_AS_ERRORS=1 swift test`：主套件 170 tests；transport 套件 21 tests，
  新增准入与 binding 顺序 / 拒绝阶段测试运行四种 backend 组合；Session false/throw 原生拒绝覆盖两种 client backend。
- `python3 Scripts/check-public-api.py` 运行包外正例、12 个反例及 public symbol graph；
  负例检查编译失败与诊断中的核心符号，不依赖具体措辞。symbol graph 仅检查 6 个 required / 3 个 removed 名称，
  没有基线 diff，不自动阻止任意新增 public 符号；`.build/public-api-verification` 保留 probe、诊断与 owned API 清单，CI 上传供人工审查。
- `swift format lint --strict --recursive Sources Tests`、`git diff --check` 无问题。
- `Examples/DistributedXPCDemo` 的 warnings-as-errors 独立 package 构建通过。

这些结果来自当前 macOS 26 本机；未以旧 PR HEAD 的 CI 结果替代本地验证。

后续取消语义修复增加无载荷 `cancelled` 回复，wire version 升至 2，两端需同时升级。
服务端 Task 的 CancellationError 在客户端保持为 CancellationError，不再转换成目标执行失败，且不关闭通道。

macOS 26 typed requirement 的构造与运行时安装现由带 `@available` 的 launchd 集成测试覆盖：
临时 named Session 服务对两种 ad-hoc 签名客户端执行 `.hasEntitlement` 策略，分别验证放行、
内核拒绝不进入 Delegate/交付 handler，以及拒绝后服务仍可用。不需开发者证书，结束后卸载 job；
该用例验证 requirement 的实际安装，不代替 team/platform 身份策略各自的集成矩阵。
