// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

@available(macOS 15, *)
public struct XPCInvocationResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = XPCMarshal
  private let sendEnvelope: @Sendable (XPCReplyEnvelope) throws -> Void

  init(_ sendEnvelope: @escaping @Sendable (XPCReplyEnvelope) throws -> Void) {
    self.sendEnvelope = sendEnvelope
  }

  init(received: SwiftXPC.XPCDictionary) {
    self.sendEnvelope = { envelope in
      guard var reply = XPCDictionary(replyTo: received), let connection = received.remoteConnection
      else { return }
      try envelope.write(to: &reply)
      connection.sendAndForget(message: reply)
    }
  }

  func send(_ envelope: XPCReplyEnvelope) throws { try sendEnvelope(envelope) }

  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    try send(XPCReplyEnvelope(kind: .returnValue, payload: try value.marshal()))
  }

  public func onReturnVoid() async throws { try send(XPCReplyEnvelope(kind: .returnVoid)) }

  public func onThrow<Err: Error>(error: Err) async throws {
    guard let error = error as? any ErrorXPCMarshal else {
      throw XPCRemoteCallError.unsupportedThrownErrorType(String(describing: Err.self))
    }
    try send(XPCReplyEnvelope(kind: .throwError, payload: try error.marshal()))
  }
}


typealias ErrorXPCMarshal = XPCMarshal & Error
