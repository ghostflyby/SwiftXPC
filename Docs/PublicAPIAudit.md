# 公开 API 面审计与收拢

审计基线是 `b5c75d5`，覆盖两个 runtime product 的自有公开声明、标准类型扩展和宏生成代码的支撑符号。
以 `swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members` 核对声明集合；
Apple XPC / Swift 标准库的再导出不逐个视为本库的新抽象，compiler plugin 的实现类型也不属于 runtime product。
业务载荷序列化布局不变。取消回复新增 `XPCReplyKind.cancelled`；wire version 升至 2，旧版本 peer 明确拒绝。

判断顺序是：接口实际解决什么问题；能否由现有接口可靠替代；保留它带来的调用便利是否值得；
是否把只有某一后端或某一生命周期阶段才成立的操作放到了通用类型上。
“可用底层代码代替”并不自动意味着删除，否则任何高层 API 都无法成立。
但只有转发、公开内部装配、重复命名或没有效果的参数，不作为独立功能保留。

## Delegate 与监听准入

| API 面 | 必要功能 / 替代方案 | 粒度与处理 |
|---|---|---|
| `XPCServiceDelegate` | 通道绑定成功、绑定失败、已绑定 peer 结束、显式服务关闭；两个后端都有这些服务事件 | 仅保留 `didAcceptPeer`、`didRejectPeer`、`peerDidEnd`、`serviceWillShutdown`。不承担 native admission 或进程入口 |
| `XPCConnectionServiceDelegate` | 未激活 C connection 的身份审核、逐 connection 的字符串 requirement、native 拒绝通知 | 继承公共协议；`shouldAcceptConnection` / `didRejectConnection` 直接使用 `XPCConnection`。不需要检查可选 channel.connection |
| `XPCSessionServiceDelegate` | 在 Listener incoming request 内决定 native accept/reject | 继承公共协议；`shouldAcceptSessionRequest` / `didRejectSessionRequest` 使用借用的原生 request。库负责 native decision 和 handler，Delegate 不调用 request.accept/reject 或持有 request |
| 两个 `*ServiceConfiguration` | 可由自定义 conformer 替代；为一次性服务与测试提供简洁的 closure 形式 | 保留两种完整、后端专用的配置，避免再要求组合 lifecycle 配置、准入策略和转发对象。closure 存储是 private，public 行为仅通过协议方法表达 |
| `XPCServiceHost.bind(_:)` | 绑定已经 native admitted 的 channel；维护 peer 与关闭状态；支持非 actor 服务 | 改名明确阶段。host 只消费公共协议。直接使用 host 的低层调用方需自行完成 native admission；actor service 自动组装完整路径 |
| `XPCChannelAcceptor` 的两个专用构造入口 | 用编译期约束选择准入协议；C Delegate 不能传入 Session 入口 | 保留同一个 listener owner，不再新增两个 listener wrapper 或 runtime downcast。公共构造器一次接收 delivery handler，取消公开的 handler setter |
| named Session listener 的 typed requirement 构造器（macOS 26+） | Apple 原生 `XPCPeerRequirement` 策略；不能可靠地当成旧 C 字符串 requirement | 保留为 Session 专用、具 availability 的入口，明确必须有 mach service 名。不能用“旧系统跳过一个不可用 Delegate getter”实现安全策略，否则会默默失去校验。Kernel 丢弃的请求不会触发 native rejection hook；不宣称支持匿名 export listener 的同等策略 |
| runtime `transport.acceptor(handler:)` | 无自定义准入策略的 listener；actor-reference export 与运行时后端选择 | 保留。自定义准入走专用 Delegate 构造器，没有 Delegate + runtime transport 的混搭入口 |
| admission / binding 两种拒绝通知 | native admission 失败时尚无 library channel；routing 绑定失败时已经有 channel | 两个阶段不可合并成“一个被取消的 peer”。native failure 走专用协议；binding failure 走公共 `didRejectPeer`，不会再触发 native rejection hook |

公共默认实现只表示“此通知没有自定义处理”或“准入策略默认接受”。
Session 类型根本没有 C 身份、C requirement 安装或 interruption 注册方法，不依赖空实现伪装能力。

服务级生命周期的 `didAcceptPeer` 表示服务绑定完成、业务消息尚未开始分发。
Session request 在 native callback 内审核；false / throw 都生成原生 reject，accepted channel 不会被交付。
native accept 之后的 handler 配置仍在 callback 内完成，channel delivery 排到同一串行 queue；
这里的库级 activate 是消息分发门控，不被描述为 native Session 激活前的通用审核窗口。

## 通道、原生 API、序列化

| API 面 | 必要功能 / 替代方案 | 粒度与处理 |
|---|---|---|
| `XPCChannel` 的构造、`transport`、`activate/cancel` | owned 双向通道，封装两套不同 native ownership 与 activation 规则 | 保留一个具体 owner。Session adapter 是内部实现，不公开重复的 protocol / wrapper。cancel 在所有阶段终局安全 |
| `setIncomingHandler`、`send`、`sendAndForget` | 双向接收、等待 reply、无 reply 的发送；三者语义不同 | 保留。handler 在业务层需要安装；raw service 与 actor runtime 都使用。通用 send 不暴露 native queue 参数 |
| `addInvalidationHandler` / `waitForDisconnection` | 即时通知与 async 等待两种消费方式；C 的首次 interruption 与 terminal invalidation 不相同 | 保留。用 continuation 代替 handler 会让每次生命周期通知都要求单独 Task；用 polling 代替 wait 会丢确定性 |
| `XPCChannel.connection` | 显式访问 C wrapper 上的 native 专属能力，支持调用方已有 C 代码 | 保留唯一的可选后端入口；删除 channel 上复制的 `pid/euid/egid/asid`、requirement 安装及 public interruption 注册，不再复制一组带 nil/no-op 的 C API |
| `canReconnect` | 原先只是 `transport == .cConnection` 的计算别名；也不保证 endpoint listener 仍存活 | 删除。root retry 内部使用 backend 与实际 `.interrupted` outcome 决定，不把它公开为连接能力承诺 |
| `XPCIncomingMessage.payload/reply` | 异步、跨 handler 返回后的 reply capability；C 与 Session reply 机制不同 | 保留为一个值，reply 状态由所有副本共享。直接暴露两个 native reply 方式会让每个服务重复分支 |
| `XPCChannelTransport.channel(dialing:/xpcService:/machService:)` | endpoint、XPC service 与 Mach service 三种 native 地址；客户端及 actor import 的运行时后端选择 | 各签名明确 native 地址类别：XPC service 用 bundle identifier，Mach service 用 launchd `MachServices` 名。后端选择不改变寻址空间；统一验证 endpoint 类型 |
| acceptor 的 `wireEndpoint`、`activate/cancel` | 导出可交换 token、开始监听、停止监听；与既有 peer 通道生命周期不同 | 保留。public handler 在构造时固定；并发激活未完成时抛 `ActivationError.inProgress`，完成后的重入幂等。取消阻止新的 callback claim，已 claim 的回调允许结束；host 关闭拒绝迟到绑定。仅 package 内为 export session 的分阶段初始化保留安装步骤 |
| `XPCConnection` 的 native 构造、event handler、target queue、activate/cancel | 未采用 owned channel 时的 C 使用模式；native 事件、队列与 listener 选项不能由通用 channel 代替 | 保留为一个低层 surface。不是另一个所有权 facade，不在通用 channel 复制这些成员 |
| native async / sync / forget send | await reply、阻塞 reply、无 reply；sync API 有独立使用场景 | 保留；删除 sync send 的 `replyQueue`，原生 sync API 无队列参数且此前传入值从未被使用 |
| native invalidation / interruption / termination-imminent / signing-error hooks | 不同 C 原生事件，部分可重复或有进程退出含义 | 保留在 native 类型。泛化为 Session 回调无等价语义，不上移到公共通道 |
| native `pid/euid/egid/asid` | C 准入窗口的身份信息 | 保留；accepted connection 保留身份快照，终止后仍可用于通知记录。Session 不提供这些访问器 |
| native `name/debugDescription/invalidationReason` | 地址信息、对象诊断、终局原因，内容并不相同 | 保留。copy 出来的诊断字符串释放 native allocation；修正此前 invalidationReason 的释放遗漏 |
| native `setPeer*Requirement` 各 overload | 字符串、entitlement、team/platform 的不同 kernel 策略；不是 Delegate 的通知 | 保留；Bool/Int/String overload 提供类型约束。安装只能执行一次的 native 限制仍明确写在文档 |
| `XPCPeerRequirementError`（声明在 XPCConnection.swift）、`XPCChannelError` | requirement 安装的 errno 状态与传输发送的 typed outcome | 保留两个错误域；删除重复的 `XPCConnection.PeerRequirementError` typealias。没有把 native 安装错误揉成一个无细节的 channel invalid |
| `XPCConnection.marshal/unmarshal` | 既有 C 代码的 endpoint 交换、`XPCMarshal` conformance | 保留；不能把现有 native C 用户都迫使采用 owned channel。高层用户使用 transport factory，不需要两条路径都调用 |
| `XPCMarshal`、`@XPCMarshal` | 手写 codec 契约与编译期合成；支持 raw handles、布局和 typed errors | 保留，不引入另一个 message codec / Codable adapter。macro 生成与手写 codec 都实现同一协议 |
| `XPCMarshalError.Kind`、构造 helpers、description | codec 与 actor-reference 导入的结构化诊断 | 保留同一错误值；helpers 是 enum case 的便利构造，未引入新的错误包装层 |
| 基础类型、Data/Date/UUID/FileHandle、Optional/Array/Dictionary 的 codec | 支持这些值的 wire 编解码；仅靠 native getter 不能替代通用组合与范围检查 | 保留按 Swift 类型的 conformances，而非每种 layout 再新增 public 类型 |
| XPCDictionary/XPCArray 的 raw object、reply、remoteConnection、append、Sequence 扩展 | 补齐 native 容器在 raw handle / C reply / 遍历处的缺口 | 保留 SDK 的容器，不再自造第二套容器和 subscript 词汇；C 专属 reply helper 在已有 native dictionary 上，不承诺 Session 对等 |
| `XPCMarshalRuntime` | macro 展开到外部模块后必须可访问的 validation / value helpers | 将原来 7 个顶层 type 常量、type/getter/create aliases 收进一个 compiler-support namespace；合并重复的 type-check 模板。不作为正常应用的新增一层 codec |
| `xpcCopyDescription` | 将 allocated C string 转为 Swift string 并清理内存 | 保留单个诊断便利；`xpcTransactionBegin/End` 等纯别名删除，直接用再导出的 native API |
| `SwiftXPC` 再导出 Apple `XPC` | raw-handle interop 与 SDK 容器直接使用；另一方案是每处再 import XPC 或自建 aliases | 保留再导出，避免制造一套库自己的 native 类型别名。Apple SDK 的所有符号不另建 SwiftXPC wrapper |

## Actor 服务、客户端与测试工具

| API 面 | 必要功能 / 替代方案 | 粒度与处理 |
|---|---|---|
| `XPCActorService.root/host` | root 访问与服务控制；维持 root/registry/peer 的具体生命周期 | 保留一个服务 owner；不再公开 `.system` 这一重复入口，必要时 root 已有 `.actorSystem` |
| actor service 的两个 Delegate initializer 与 root factory | 静态绑定后端策略；为 root 注入业务依赖 | 两个 async throws initializer 仅接受对应 typed delegate；factory 属于协议必需方法，无 runtime transport 混搭入口 |
| `XPCActorService.listen` | 自动使用同一个 Delegate 创建 listener、固定 host routing、激活并持有 listener | 新增以替代普通应用的多个装配步骤。service 关闭会关闭自己创建的 listeners；返回值用于 endpoint 访问和单独取消某个 listener，不要求调用方额外维持 listener 生命周期 |
| `XPCActorService.cancel` 与 host `requestShutdown` | silent teardown 与有通知/完成动作的 cooperative shutdown | 保留语义差异。关闭等待 peer 钩子后执行 willShutdown、registry 清理、didShutdown；cancel 不启动异步钩子且终局。actor service 不再有独立 completion 闭包 |
| `XPCServiceHost` 的 routing / completion 构造参数 | raw service 自定义路由、embedding 的关闭完成动作 | 收拢到一次构造。删除 `setPeerHandler/setShutdownCompletion`；actor service 的 cleanup 不会被外部 replacement setter 覆盖 |
| `XPCRootActor` / `XPCExportableActor` | root 有初始化约束；exportable child actor 只需可编码引用 | 保留两种协议，不能将所有 child 都要求为 root。macro 自动实现 export conformance |
| `XPCExportableActor.unmarshal(from:transport:)` | runtime 之外单独导入时指定后端；常规 unmarshal 从 runtime 解码上下文继承 | 保留显式入口；没有重新引入进程全局 default / policy builder |
| `XPCRootActor.connect` 与 `XPCRootConnection.connect` | 只要 actor 的简洁用法，与需要 events/retry/close 的资源 handle 用法 | 保留这两种调用模式；不是两套连接实现。`toService:` 保持 XPC service 寻址，`machService:` 显式选择 Mach service；transport 只选择后端。native C authentication 仅在 `using: XPCConnection` overload，通用 channel / transport connect 不再接收 C-only requirement 字符串 |
| `XPCRootConnection.root/connection/events/close` | actor 调用、通道控制、观察断连、结束 stream 与连接 | 保留一个客户端 owner。`.ready` 只说明本地 proxy 已创建，不代表握手或 native connection 已建立；`.disconnected` 通知可用于重建 child 状态 |
| `XPCRetryPolicy` 与 `retrying` | 调用方控制次数/backoff，处理可恢复 C interruption | 保留一个值与一种操作。`once/resilient` 是常用策略，不额外新增 retry controller 或 Session 重连模式 |
| `XPCDistributedActorSystem` 的构造、transport、可选 connection | 本地 registry 与 remote proxy 两种 compiler runtime 用途；immutable import/export 后端策略 | 保留同一个编译器要求的 actor system。拆成两个 system 类型会扩散到 actor 的关联类型与跨服务 forwarding；只有 proxy 有 outbound connection，nil 在这里是实际状态，不是假身份能力 |
| actor system 的 assign/resolve/ready/resign/encoder/remoteCall 等 | Swift DistributedActorSystem conformance，编译器直接依赖 | 必须 public，不能用隐藏内部路由来替代。内部 bind/export/registry/metadata lookup 不增加 public 管理器 |
| `requestServiceShutdown` | actor 业务代码触发所属服务的 cooperative shutdown，而无须知道 listener / 进程入口 | 保留一个桥接操作；未挂载服务的 local/proxy system 不会拥有服务关闭入口 |
| `XPCActorID` | actor identity 的可比较 wire 值与 root ID | 保留一个类型，不增加 per-peer context / root identity wrapper |
| `XPCInvocationEncoder/Decoder/ResultHandler` | compiler 关联类型及对应记录、解码、结果输出协议 | 保留 compiler 必需的 public type/method；routing closure、transport context、构造细节保持内部，不作为可独立装配的 public 层 |
| `XPCDistributedTargetMetadata` / `…Providing` / `@XPCService` | 外部模块的宏必须生成可访问的 method whitelist 和 typed-throws metadata | 保留；内部解析与查表仍是内部函数。metadata、export、service 并非三套不同 dispatch registry |
| `XPCReplyKind` / `XPCRemoteCallError` / `XPCDispatchError` | wire error 中可判别的 reply kind、客户端解码错误与服务端派发错误 | 保留分别可编码、可比较的错误域；取消独立为无载荷的 cancelled 回复，客户端抛 CancellationError，不使用业务错误类型解码；invocation/reply envelope 和 version negotiation 不公开成另一个 wire API 产品 |
| low-level `SwiftXPC.xpcMain` / actor `xpcMain(delegate:)` | 原生进程入口与 actor 服务启动 | 保留两种实际用途；删除 `XPCApp`，两个专用 actor delegate 都提供默认 static main，具体类型可直接标注 @main；入口使用 init() 构造 delegate |
| `xpcSessionMain` | 必须有 mach service 名的 Session 进程入口 | 保留专用入口，不用 runtime flag 假装能替换 bundled C xpc_main。Session Delegate 不继承 C-hosted app 协议 |
| `XPCActorServiceDelegate<Root>` 及 C/Session 子协议 | 实际 root 的创建与各阶段异步配置；后端专属同步原生准入 | 必需 root factory，其他钩子默认空实现；每个钩子均有 typed service。专用协议要求 init()，Session 要求 static serviceName，分别为默认进程入口提供实例和 launchd 名称。删除独立 onStart/onShutdown/makeRoot 闭包，所有启动入口使用同一管线 |
| `xpcTest` / `XPCRootTestCoordinator` | 管理真实 in-process 服务、匿名 listener、production client、watchdog | 保留确定性 integration harness。C / Session 的自定义 Delegate 各有约束；取消 runtime actor-service overload；矩阵测试在内部显式分支选择专用入口，避免默默忽略专用方法 |
| coordinator 的 client/service/transport/makeClient/dropServerPeer/close/waitUntilClosed | 多客户端、模拟失联、整个 fixture 收尾，与 production client 控制不同 | 保留这些 test-only 操作。公开 typed service 取代重复 host 属性；事件等待调用 log，关闭等待调用 service.host |
| `XPCServiceEvent` / `XPCServiceEventLog` | 无 missed edge 的有序 hook 时间线和 occurrence 等待 | 保留 recorder、snapshot 和唯一 `wait(for:occurrence:timeout:)`。删除 `expectEvent/expectCount` 两种等待入口及 public append；Kind 与 hook 对齐：`didRejectConnection`、`didRejectSessionRequest`、`didRejectPeer` 分别表示两个 native admission 和 host binding 阶段；固定 Kind 不能表示任意用户 marker，公开写入会污染 production hook 时间线 |
| `DistributedXPC` 再导出 SwiftXPC | public actor API 的实际参数均来自 SwiftXPC；省去反复 import | 保留模块依赖再导出，不增加 umbrella facade 或第二套对应类型 |

## 使用方式与迁移

普通 actor 服务只保留一个 owner，不再手动构造和绑定多个 public 层：

```swift
struct NativePolicy: XPCConnectionActorServiceDelegate {
  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> ServiceRoot {
    ServiceRoot(actorSystem: actorSystem)
  }
  func shouldAcceptConnection(_ peer: XPCConnection, in service: XPCActorService<ServiceRoot>) throws -> Bool {
    peer.euid == geteuid()
  }
}
let service = try await XPCActorService(NativePolicy())
try await service.listen()
// Retain service while serving; it retains its listeners.
```

Session 使用另一组明确的约束：

```swift
struct SessionPolicy: XPCSessionActorServiceDelegate {
  static var serviceName: String { "com.example.service" }
  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> ServiceRoot {
    ServiceRoot(actorSystem: actorSystem)
  }
  func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<ServiceRoot>) throws -> Bool {
    true
  }
}
let service = try await XPCActorService(sessionDelegate: SessionPolicy())
try await service.listen()
```

低层 raw service 保留 native admission 与 service binding 的区分；handler 固定在构造时：

```swift
let policy = XPCSessionServiceConfiguration()
let host = XPCServiceHost(policy, peerHandler: { channel in
  channel.setIncomingHandler { message in message.reply(message.payload) }
})
let listener = try XPCChannelAcceptor(sessionDelegate: policy, handler: { host.bind($0) })
try listener.activate()
```

需要 macOS 26 named Session listener 的 typed requirement 时，使用其专用构造器；
不把这个能力冒充通用 channel 的字符串 requirement 安装：

```swift
let listener = try XPCChannelAcceptor(
  sessionDelegate: policy, service: "com.example.service",
  requirement: .isPlatformCode(), handler: { host.bind($0) })
```

| 原 API | 迁移 |
|---|---|
| `XPCServiceConfiguration` | `XPCConnectionServiceConfiguration` 或 `XPCSessionServiceConfiguration` |
| `shouldAcceptPeer(channel)` | `shouldAcceptConnection(connection)` / `shouldAcceptSessionRequest(request)` |
| native admission 的 `onPeerReject` | `onConnectionReject` / `onSessionReject`；`onPeerReject` 仅指 host binding 失败 |
| `XPCActorService(root, delegate, transport:)` | C 的 unlabeled Delegate initializer，或 Session 的 `sessionDelegate:` initializer |
| `host.accept(channel)` | native admission 后 `host.bind(channel)`；一般直接用 actor service.listen |
| `transport.acceptor(); setAcceptHandler` | `transport.acceptor(handler:)`；创建时固定 handler |
| `setPeerHandler/setShutdownCompletion` | host initializer 的 `peerHandler/onShutdown`；actor service 使用 typed delegate 阶段，不提供独立 onShutdown 参数 |
| `channel.pid/euid/...` | C Delegate 的 native connection；后端 interop 使用 `channel.connection` |
| 通用 connect 的 `peerCodeSigningRequirement:` | 在 native C connection 上配置，或 `connect(using: nativeConnection, peerCodeSigningRequirement:)` |
| `service.system` | `service.root.actorSystem` |
| coordinator / log 的多个 expect 方法 | `log.wait(for:occurrence:timeout:)`；`service.host.waitForShutdown(timeout:)` |
| 顶层 macro shims / transaction aliases | compiler helpers 使用 `XPCMarshalRuntime`；native 操作直接使用 Apple XPC API |

## 验证与边界

- warnings-as-errors 全量测试：主套件 201 tests，transport 套件 21 tests；四种 server/client 组合均覆盖。
- 新增/调整测试覆盖 native audit → binding → notification → message 的顺序、Session false/throw
  原生拒绝、两个后端的绑定失败与 native rejection 区分、直接 Session conformer、service 持有及关闭 listeners。
- Session 激活的同步取消/重入、激活过程中并发取消、创建失败后的发送结束，以及 shutdown 管线期间
  重复 cancel 不释放其 waiters；actor proxy forwarding/re-export 与并发 peers 在 C/C、Session/Session 均覆盖。
- Session incoming handler 的取消及替换均在锁外释放 captures；两个子进程测试验证 capture 析构重入
  cancel 不崩溃且 invalidation 只通知一次，原实现下两例均因递归锁崩溃而失败。
- Send sink 在锁内取出 continuation、锁外恢复，避免 native reply 与 Task.cancel 的任务状态锁反转。
  进程外确定性测试暂停回复恢复，同时要求取消完成；旧锁策略失败，修复后通过。
- 从包外 typecheck 三组正确用法（通用 API、两个无需自行实现 main 的 @main delegate，含 macOS 26 typed Session requirement），并验证 20 种错误调用被拒绝：
  缺失入口 init/serviceName、双后端入口未选择 main、Delegate / backend 错配、Delegate + runtime transport、缺失 delivery handler、缺失 named security service / nil service、C-only channel 身份 /
  requirement / interruption、公开替换 host / listener routing。
- 独立 `Examples/DistributedXPCDemo` build、bundled C 入口的 C/Session 客户端与协作退出通过。
- `Scripts/check-actor-service-lifecycle.py` 实测 bundled C 与 launchd Session 入口、两种客户端、异步
  factory 与 root 准备；12 组进程用例验证挂起关闭钩子期间服务端存活，完成后成功退出 0、cleanup
  失败或裸取消退出 1。C 侧通过 kqueue 读取服务进程 wait status，Session 侧读取 launchctl 状态。
  C 入口保留进程生命周期 transaction，防止最后一条消息释放后 idle exit 截断异步清理。
  另有确定性测试验证 HostedActorService 在启动关卡关闭期间暂存 native connection。
- typed actor delegate 覆盖独立启动/绑定关卡、失败回滚、关闭等待与 registry 清理、迟到绑定拒绝、
  root/host 不保活 service、排队 RPC 关闭后不执行，以及 watchdog/caller cancellation 覆盖异步启动。
- 提前激活覆盖 will-bind 与 did-bind：收到 invocation 的确定性信号到达后，关卡仍阻止执行。
  执行中的启动/用户钩子会保活 owner，必须协作取消；取消 listen 终止共享启动。测试释放 gate 后
  等待启动任务结束，验证 registry 已清空。协调器构造失败等待协作清理，清理开始后的迟到绑定
  不启动异步通知，避免与关闭钩子并行或被进程退出截断。
- `swift format lint --strict --recursive Sources Tests` 与 `git diff --check` 通过。

这次没有改变业务载荷布局；取消回复扩展使 wire version 升至 2，需要两端同时升级。没有把 anonymous export endpoint 的 capability 模型升级为
named listener 的 typed peer requirement 策略。macOS 26 constructor 除包外类型检查外，现有
`@available(macOS 26.0, *)` 的真实 launchd 集成测试。fixture 直接调用带 requirement 的构造器；
临时注册 named Mach service，用 ad-hoc 签名客户端验证 `.hasEntitlement`：携带 debug entitlement
的 peer 可以收发，缺失该 entitlement 的 peer 被拒绝，且没有进入准入/交付/拒绝钩子；随后匹配 peer
仍可调用。测试不依赖开发者证书，卸载 job 并清理临时文件，超时必失败。
覆盖的是该构造器安装 typed requirement 的内核强制行为，不据此宣称所有 team/platform requirement 均已集成覆盖。


## 后续 P2/P3 核验（2026-10-03）

| 审查项 | 核验与处理 |
|---|---|
| mainHandler 在锁内调用用户代码 | 原表达式先结束 withLock 再调用返回的 closure，没有该问题；改为两行显式快照。补底层 xpcMain 的 launchd 约束 |
| 并发 listener 激活提前成功 | 存在；重入抛 inProgress，失败 owner 回滚后可重试。确定性测试阻塞并使首轮激活失败 |
| cancel 后已捕获的 delivery | 存在在途窗口；审核后重新检查状态、取消清除 handler。已经完成 claim 的回调允许结束，文档明确；不持锁执行用户代码或等待重入回调 |
| Session send 错误分类较粗 | 保留统一 fail-stop 策略：任一 native send 失败终结 channel/全部 reply 等待者，包括 canRetry 错误。XPCRichError 没有 C 的类型化 reason，不能靠文本推断 signing/interruption，也不自动重发可能已投递的调用 |
| onShutdown 不对称 | actor 服务及 xpcTest 统一使用 typed serviceDidShutdown；取消单独 completion 闭包和 runtime 构造器 |
| decoder 默认 C transport | 删除默认值，强制内部构造点显式传入后端 |
| 错误回复再次编码失败 | catch 所有 failure；编码失败时发送无 payload 的合法 throwError envelope，客户端确定性报 missingPayload；不再 try? 吞掉此路径。覆盖 custom encoder 失败及非 marshalable 错误 |
| graceful shutdown 断言过宽 | 将断言收紧到 invalid/interrupted，明确排除 signing error。raw host listener 继续监听时另测 shutdown 后 binding rejection(nil)，C 精确断言 interrupted、Session 精确断言 invalid |
| 重复/白盒/无 watchdog 测试 | 删除重复 Session host 文件并将 completion 断言并入矩阵；重命名并删除重复 backend 断言。registry 验证改用 resolve；保留 SendSink 白盒测试以确定性覆盖 continuation 安装前的 first-result 竞态。service/coordinator fixture 增加 watchdog |
| sleep 与超时误报 | accept delivery、drain waiter 注册、延迟 reply 取消和 client 断连改用信号。并发 listener 测试的超时取消允许 CancellationError；其余短暂 sleep 仅扩大 pre-activation 窗口，不作为通过条件 |
| 外来 root factory | 进程外 exit test 验证 foreign system 触发指定 precondition，检查 stderr 原因 |
| 服务端 Task 取消 | onThrow、派发 catch 与错误回复均保留 CancellationError；无载荷 cancelled 回复在返回值/void 客户端路径都还原 CancellationError。C/Session 真实 Task 取消与随后调用成功均有覆盖 |
| 验证主张留痕 | `python3 Scripts/check-public-api.py` 实际执行包外正例、20 个负例（编译失败且 error: 诊断正文包含核心符号整词，排除文件名和源码回显）和 symbol graph。缺失 init/serviceName 两例额外要求 error/note 诊断正文包含具体 requirement，不能只靠协议名通过。输出 `.build/public-api-verification`，CI 同步运行并上传证据。symbol graph 仅校验 9 个 required / 4 个 removed 顶层名称，记录完整 owned 清单；没有入库基线 diff，不能拦截任意新增 public 声明，增量仍需人工比较 artifact 与本审计 |
