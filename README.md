# SwiftXPC

Swift wrappers for Apple's XPC IPC layer plus a `DistributedActorSystem` that
carries [distributed actors](https://developer.apple.com/documentation/swift/distributedactors)
over XPC channels.

Two products ship from this package:

| Product | Contents |
|---|---|
| `SwiftXPC` | Swift vocabulary over Apple's XPC: the `XPCDictionary`/`XPCArray` containers (re-exported from Apple's `XPC` module, extended with reply, endpoint, and element accessors), `xpc_object_t` as the marshal currency behind the `XPCMarshal` serialization protocol + macro, `XPCConnection`, the dual-backend transport layer (`XPCChannel`, `XPCChannelTransport`, `XPCChannelAcceptor`), and the actor-free service layer (`XPCServiceDelegate`, `XPCServiceHost`) |
| `DistributedXPC` | A distributed actor runtime on top: `XPCDistributedActorSystem`, root-actor service bootstrap (`XPCActorService` with one `XPCRootActor` per service, typed lifecycle delegates with built-in `@main` entry points, `xpcSessionMain` for session-backed services), cross-process actor references (parameters, return values, forwarding), and a resilient `XPCRootConnection` handle |

## Raw handles and Sendability

The public currency at every API boundary is the raw `xpc_object_t` handle —
the same type Apple's `XPC` module exposes — with no library-owned wrapper
type. This is deliberate:

- **Interop is zero-cost.** Handles move between SwiftXPC, Apple APIs, and
  libxpc's C entry points without conversion.
- **Single vocabulary.** There is no second handle type to pick between at
  call sites.

`xpc_object_t` is deliberately *not* `Sendable` (Apple's overlay leaves it
that way: `xpc_dictionary` objects are mutable after creation, so a blanket
assertion would be false in general). The asymmetry you might want —
"`Sendable` inside the library, strict outside" — is not expressible in
Swift: conformance declarations cannot be scoped (an `internal`/`package`
refinement would still be globally visible), and retroactively refining a
foreign *protocol* to `Sendable` is a compile error (`extension of protocol
'OS_xpc_object' cannot declare inheritance relationship`; verified against
the macOS 27 SDK). The package crosses isolation boundaries internally
through a package-private unchecked-`Sendable` box, asserted at each
crossing site.

If your code needs to carry a handle across an isolation boundary, assert
the same thing locally — libxpc objects are safe to use from any thread:

```swift
struct SendableHandle: @unchecked Sendable {
  let raw: xpc_object_t
}
```

Equality, hashing, and description are available as free functions:
`xpc_equal`/`xpc_hash` (C API) and `SwiftXPC.xpcCopyDescription(_:)`.

## Transport backends

Channels ride one of two backends, selected through `XPCChannelTransport`
(`.cConnection` by default):

| | C backend (`XPCConnection`) | Session backend (`XPCSession`) |
|---|---|---|
| Peer validation | kernel-enforced C requirements | typed requirements on named listeners (macOS 26+), through the Session-specific constructor |
| Peer identity | native connection pid / euid / egid / asid | no equivalent identity accessors |
| Hosting | `xpcMain(delegate:)` (bundled `.xpc`, launchd) | `xpcSessionMain` (LaunchDaemon-style mach service) |
| Re-dial after peer loss | transparent (named services, live listeners) | terminal — never re-establishes |

Both backends share one contract:

- Endpoints are backend-agnostic — either backend can dial an endpoint
  minted by the other (covered by the parameterized test matrix).
- Pre-activation sends buffer and issue on `activate()`; awaiting a reply
  supports Swift task cancellation (the late reply is dropped, the channel
  stays usable).
- One error vocabulary (`XPCChannelError`) and one service host
  (`XPCServiceHost`, common lifecycle hooks over `XPCChannel`). Native admission uses
  `XPCConnectionServiceDelegate` or `XPCSessionServiceDelegate`.

Transport selection is explicit and defaults to `.cConnection`. Each actor
system keeps an immutable backend policy. Nested actor references inherit the
receiving system's policy during invocation or reply decoding; standalone
imports can use `Worker.unmarshal(from: payload, transport: .session)`.

Service-side invocation cancellation reaches the caller as `CancellationError`
and leaves the channel usable. The distributed wire protocol is version 2;
upgrade both peers together. Version 1 peers are rejected explicitly.

`XPCChannel` owns its native resource and cancels on deinitialization. Use
`channel.connection` for C-specific operations; identity, signing requirements,
and interruption handlers stay on `XPCConnection`. Session admission runs inside
its native incoming-request callback. Accepted messages buffer until service
binding and logical activation finish.

## Service ownership

`XPCActorService` owns one root, a local actor registry, and an actor-free
`XPCServiceHost`. Multiple clients share that root; separate service instances
have separate roots, even within one process. Local registries need no idle
XPC connection. Inject dependencies through a typed delegate factory:

```swift
struct ServiceDelegate: XPCSessionActorServiceDelegate {
  static var serviceName: String { "com.example.service" }
  let dependencies: Dependencies

  init() { self.init(dependencies: .live) }
  init(dependencies: Dependencies) { self.dependencies = dependencies }

  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> ServiceRoot {
    ServiceRoot(dependencies: dependencies, actorSystem: actorSystem)
  }

  func serviceWillStart(_ service: XPCActorService<ServiceRoot>) async throws {
    // Await root preparation here before clients can execute RPCs.
  }
}
let service = try await XPCActorService(sessionDelegate: ServiceDelegate(dependencies: dependencies))
try await service.listen(service: "com.example.service")
// Advertise this name in launchd MachServices and retain service while serving.
```

For an anonymous listener, use `service.listen()` and pass its `wireEndpoint` to
clients explicitly; it cannot be dialed by a service name.

`service.cancel()` performs terminal synchronous teardown. `service.host.requestShutdown()`
starts cooperative shutdown; await `service.host.waitForShutdown()` for peer hooks,
service cleanup hooks, and registry invalidation. Neither path drains executing RPCs.
Hosted entry points exit after awaited cleanup (status 0 on completed cooperative
shutdown, 1 on startup/cleanup failure or bare cancellation). The C entry keeps
a process-lifetime transaction so idle termination cannot interrupt these hooks.
Automatic idle exit stays disabled; disconnecting all peers does not stop the service.
Embedders never exit their process. Source documentation defines hook ordering and
startup/binding barriers.

## Breaking migration

- Replace `any XPCMessageChannel` and `XPCPeerContext` with `XPCChannel`.
- Construct Session channels through `XPCChannelTransport.session`.
- Replace `Root.shared` / `.serviceHost` with `XPCActorService.root` / `.root.actorSystem`.
- Use `XPCDistributedActorSystem()` for a local actor registry;
  `system.connection` is optional and only exists for channel-bound systems.
- Channel sends use `send(payload)`; C native sends keep their queue options.
- `.ready` replaces `.connected`: local proxy creation precedes connection
  establishment. Retry only recoverable C interruptions, not terminal errors.
- Replace `XPCApp` with the backend-specific actor delegate and mark it `@main`.
  Both protocols provide default `main()` implementations using `init()`; build
  production dependencies there and keep additional initializers for embedded use.
  Session delegates declare `static serviceName` matching launchd MachServices.
- Implement required `makeRoot(actorSystem:)`; `XPCRootActor` requires no initializer.
- Actor service construction, `listen`, and `xpcTest` are now `async throws`.
  Choose C/Session delegate overloads explicitly; runtime transport service overloads
  and separate `makeRoot` / `onStart` / `onShutdown` closures are removed.
- Cancelling a task while it awaits `listen()` cancels the entire service,
  including existing listeners and peers. This also applies to subsequent calls
  that add listeners.
- Access a test coordinator's owner through `coordinator.service`, including
  `coordinator.service.root` and `coordinator.service.host`.
- Bare host cancellation is terminal; a later shutdown request does not run hooks.

The delegate/API cleanup also removes channel-level C identity and security
methods, mutable host/listener routing setters, and duplicate test wait helpers.
See [the public API audit](Docs/PublicAPIAudit.md) for each surface's purpose,
alternatives, retention/removal decisions, and migration examples.

## Requirements

- macOS 15+
- Swift 6.2 toolchain

## Installation

```swift
dependencies: [
  .package(url: "https://github.com/ghostflyby/SwiftXPC.git", from: "0.1.0")
]
```

`import DistributedXPC` is enough — `SwiftXPC` is re-exported.

## Quick start

Define the service's root actor in a module shared by both processes:

```swift
@XPCService
distributed actor ServiceRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func makeWorker() -> Worker {
    Worker(actorSystem: actorSystem)
  }
}
```

Serve it from the XPC service process. The delegate itself can carry `@main`:

```swift
@main
struct ServiceMain: XPCConnectionActorServiceDelegate {
  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> ServiceRoot {
    ServiceRoot(actorSystem: actorSystem)
  }

  func peerDidBind(_ peer: XPCChannel, to service: XPCActorService<ServiceRoot>) async {
    // Register client state on service.root before its first RPC.
  }

}
```

Native identity and requirement audit belongs in the C-specific synchronous hooks.
Session services implement `XPCSessionActorServiceDelegate`, declare
`static var serviceName: String`, and also use `@main` directly. Both protocols
provide the process entry; a type conforming to both must implement `main()` to
choose its backend. Explicitly configured instances can still be hosted with
`xpcMain(delegate:)` or `xpcSessionMain(service:delegate:)`.
Both inherit typed service/peer lifecycle hooks;
`serviceWillStart`, `serviceDidStart`, `peerWillBind`, and `peerDidBind` gate dispatch.
Every notification defaults to a no-op; only root construction is required.

For in-process tests, use the same delegate with `xpcTest`. Each coordinator owns
an independent production service and client; no process exit occurs. The event log
records native admission and host events, while a delegate can record its typed
asynchronous lifecycle stages:

```swift
let log = XPCServiceEventLog()
let coordinator = try await xpcTest(ServiceMain(), eventLog: log, watchdog: .seconds(10))
defer { coordinator.close() }
let worker = try await coordinator.client.root.makeWorker()
#expect(worker.id != .root)
coordinator.service.host.requestShutdown()
#expect(await coordinator.service.host.waitForShutdown(timeout: .seconds(5)))
```

Connect from the client process and call across the boundary:

```swift
let connection = try XPCRootConnection<ServiceRoot>.connect(toService: serviceIdentifier)
let root = connection.root

// Child actors arrive as proxies on their own XPC channels and can be passed
// back as arguments (forwarding) — marshaling is generated by @XPCService.
let worker = try await connection.retrying { _ in try await root.makeWorker() }
print(try await worker.greet(name: "world"))
```

## Model

- **One service, one root.** An `XPCActorService` owns the root and actor
  registry. Each accepted root channel serves that same instance. Per-client
  state belongs in the child actors the root hands out.
- **One channel, one actor.** The initial mach-service channel serves the root
  actor (`XPCActorID.root`); every returned actor reference exports a fresh
  anonymous channel. Calls on a channel execute in FIFO order through async tasks; suspended
  calls do not block the XPC event queue.
- **Recoverable C root.** A C root proxy rides a named connection: when the
  service dies, launchd relaunches it and the same proxy works again on its
  next call. Child proxies do not survive a restart — re-acquire them via the
  root (see `XPCRootConnection.retrying` and the `events` stream). Session
  channels require a fresh root connection after peer loss.
- **Typed errors.** Serialization failures throw `XPCMarshalError`; dispatch
  and remote-call failures throw `XPCDispatchError` / `XPCRemoteCallError`.

See [Docs/XPCSessionMigrationFeasibility.md](Docs/XPCSessionMigrationFeasibility.md)
for the study comparing this implementation with the newer `XPCSession`
API family. [Architecture review and migration](Docs/DualTransportRefactorModel.md)
records the redesigned layers and regression coverage; `TODO.md` tracks the roadmap.

## Platform support

SwiftXPC is macOS-only by design (XPC does not exist on other platforms).
Multiplatform consumers keep working by scoping the dependency to macOS on
their side — the package never needs to declare other platforms:

- **Package consumers**: attach the dependency to macOS-only targets, or add
  a condition to the target dependency so iOS builds never touch it:

  ```swift
  .target(
    name: "MyMacService",
    dependencies: [
      .product(name: "DistributedXPC", package: "SwiftXPC",
               condition: .when(platforms: [.macOS]))
    ]
  )
  ```

- **Xcode app targets**: add the package product with a macOS platform
  filter, and gate call sites with `#if os(macOS)`.
- For a distributed actor shared across platforms, switch the actor system
  with a conditional typealias:

  ```swift
  #if os(macOS)
  typealias AppActorSystem = XPCDistributedActorSystem
  #else
  typealias AppActorSystem = SomeOtherSystem
  #endif
  ```

### Build strictness

The manifest never forces `-warnings-as-errors` onto consumers: xcodebuild's
package integration injects `-suppress-warnings` into remote dependencies, and
swiftc rejects the combination. The flag is opt-in via
`SWIFTXPC_WARNINGS_AS_ERRORS=1 swift build` (set only by this repo's CI), which
reproduces the strict CI build locally.

## Status

Pre-1.0: the wire protocol and API surface may still change. Known limits are
tracked in [TODO.md](TODO.md) (no generic distributed methods, no existential
actor references, local-actor export only).

## License

Apache-2.0. See [LICENSE](LICENSE).
