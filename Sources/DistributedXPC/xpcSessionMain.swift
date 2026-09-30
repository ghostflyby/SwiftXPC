// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import SwiftXPC

/// The session-backend process entry point: serves `Root.shared` over an
/// `XPCListener` bound to the launchd mach service name `service`, through
/// the same unified `XPCServiceHost` (delegate hooks, requirement
/// enforcement, cooperative shutdown) as the C backend, and never returns.
/// Requires the job's launchd configuration to advertise the mach service;
/// bundled-`.xpc` services are C-backend-only (`xpcMain`).
@MainActor
public func xpcSessionMain<Root: XPCRootActor>(
  service: String,
  _ rootType: Root.Type = Root.self,
  delegate: some XPCServiceDelegate = XPCServiceConfiguration()
) -> Never {
  let server = XPCServiceHost(rootType, delegate, transport: .session)
  // The hosted service *is* the process: retire it right after the
  // delegate's shutdown hook has run.
  server.setShutdownCompletion { exit(0) }
  delegate.serviceWillStart(host: server)
  let acceptor: XPCChannelAcceptor
  do {
    acceptor = try XPCChannelTransport.session.acceptor(service: service)
  } catch {
    FileHandle.standardError.write(
      Data("xpcSessionMain: cannot create listener for \(service): \(error)\n".utf8))
    exit(1)
  }
  acceptor.setAcceptHandler { channel in server.accept(channel) }
  do {
    try acceptor.activate()
  } catch {
    FileHandle.standardError.write(
      Data("xpcSessionMain: cannot activate listener for \(service): \(error)\n".utf8))
    exit(1)
  }
  dispatchMain()
}
