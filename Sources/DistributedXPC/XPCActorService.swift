// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC

/// Owns one root and its actor registry, independently of listener construction.
/// The host handles peer admission; the system handles actor calls and exports.
/// Retain the service for its entire serving lifetime. Keeping only its host
/// or root does not keep the service alive: deinitialization cancels peers and
/// invalidates the registry and exported references.
public final class XPCActorService<Root: XPCRootActor>: Sendable {
  public let root: Root
  public let host: XPCServiceHost
  public let system: XPCDistributedActorSystem

  public init(
    _ rootType: Root.Type = Root.self,
    _ delegate: some XPCServiceDelegate = XPCServiceConfiguration(),
    transport: XPCChannelTransport = .cConnection,
    eventLog: XPCServiceEventLog? = nil,
    makeRoot: (XPCDistributedActorSystem) -> Root = { Root(actorSystem: $0) }
  ) {
    let system = XPCDistributedActorSystem(transport: transport)
    system.reserveRootID()
    let root = makeRoot(system)
    precondition(
      root.id == .root && root.actorSystem === system,
      "The root factory must construct the first actor on the supplied system")
    let host = XPCServiceHost(delegate, eventLog: eventLog)
    self.system = system
    self.root = root
    self.host = host
    system.setServiceShutdownHandler { [weak host] in host?.requestShutdown() }
    host.setPeerHandler { [weak system, weak root] channel in
      guard let system, let root else { throw XPCChannelError.invalid }
      system.bind(channel, to: root)
    }
    host.setShutdownCompletion { [weak system] in system?.invalidate() }
  }

  public func cancel() {
    host.cancel()
    system.invalidate()
  }

  deinit { cancel() }
}
