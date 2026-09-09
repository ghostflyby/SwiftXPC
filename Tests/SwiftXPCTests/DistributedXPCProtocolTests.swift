// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import Testing

@available(macOS 13.0, *)
@Test func InvocationMessageRoundTrip() throws {
  var arguments = XPCArray()
  arguments.append(try 42.marshal())
  arguments.append(try "hello".marshal())

  let message = XPCInvocationMessage(
    method: "test",
    actorID: XPCActorID(id: 7),
    target: RemoteCallTarget("greet"),
    arguments: arguments
  )

  let encoded = try message.marshal()
  let decoded = try XPCInvocationMessage.unmarshal(from: encoded)

  #expect(decoded.version == XPCWireProtocol.currentVersion)
  #expect(decoded.actorID == message.actorID)
  #expect(decoded.target == message.target)
  #expect(decoded.arguments.count == 2)
  #expect(try Int.unmarshal(from: decoded.arguments[0]) == 42)
  #expect(try String.unmarshal(from: decoded.arguments[1]) == "hello")
}

@available(macOS 13.0, *)
@Test func ReplyEnvelopeRoundTripWithPayload() throws {
  let envelope = XPCReplyEnvelope(
    kind: .returnValue,
    payload: try "pong".marshal()
  )

  let encoded = try envelope.marshal()
  let decoded = try XPCReplyEnvelope.unmarshal(from: encoded)

  #expect(decoded.version == XPCWireProtocol.currentVersion)
  #expect(decoded.kind == .returnValue)
  #expect(try String.unmarshal(from: decoded.payload!) == "pong")
}

@available(macOS 13.0, *)
@Test func ReplyEnvelopeRoundTripWithoutPayload() throws {
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: nil
  )

  let encoded = try envelope.marshal()
  let decoded = try XPCReplyEnvelope.unmarshal(from: encoded)

  #expect(decoded.version == XPCWireProtocol.currentVersion)
  #expect(decoded.kind == .throwError)
  #expect(decoded.payload == nil)
}
