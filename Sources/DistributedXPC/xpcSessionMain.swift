// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import SwiftXPC

/// The session-backend process entry point: serves one root instance over an
/// `XPCListener` bound to the launchd mach service name `service`, through
/// shared service binding and cooperative shutdown, with Session-specific
/// native admission. Never returns.
/// Requires the job's launchd configuration to advertise the mach service;
/// bundled-`.xpc` services are C-backend-only (`xpcMain`).
@MainActor
public func xpcSessionMain<Root: XPCRootActor>(
  service: String,
  _ rootType: Root.Type = Root.self,
  delegate: some XPCSessionServiceDelegate = XPCSessionServiceConfiguration(),
  onStart: @MainActor (XPCServiceHost) -> Void = { _ in }
) -> Never {
  let actorService = XPCActorService(rootType, sessionDelegate: delegate, onShutdown: { exit(0) })
  onStart(actorService.host)
  do {
    try actorService.listen(service: service)
  } catch {
    FileHandle.standardError.write(
      Data("xpcSessionMain: cannot start listener for \(service): \(error)\n".utf8))
    exit(1)
  }
  withExtendedLifetime(actorService) {
    dispatchMain()
  }
}
