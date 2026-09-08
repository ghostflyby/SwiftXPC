// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

nonisolated(unsafe)
  private var mainHandler: @Sendable (XPCConnection) -> Void = { _ in }

private func handleIncomingConnection(_ connection: xpc_connection_t) {
  mainHandler(XPCConnection(xpc_object: connection))
}

@MainActor
public func xpcMain(_ handler: @escaping @Sendable (_ connection: XPCConnection) -> Void) -> Never {
  mainHandler = handler
  xpc_main(handleIncomingConnection)
}
