// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Synchronization
import XPC

private let mainHandler = Mutex<@Sendable (XPCConnection) -> Void>({ _ in })

private func handleIncomingConnection(_ connection: xpc_connection_t) {
  mainHandler.withLock { $0 }(XPCConnection(xpc_object: connection))
}

/// Runs the XPC service event loop, invoking `handler` for every accepted
/// peer connection. Never returns. Must run on the main thread.
///
/// For distributed actor services prefer the `xpcMain` overloads in
/// `DistributedXPC`, which layer root-actor bootstrapping on top of this
/// entry point.
@MainActor
public func xpcMain(_ handler: @escaping @Sendable (_ connection: XPCConnection) -> Void) -> Never {
  mainHandler.withLock { $0 = handler }
  xpc_main(handleIncomingConnection)
}
