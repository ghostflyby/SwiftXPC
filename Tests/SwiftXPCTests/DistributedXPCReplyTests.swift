// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC
import Testing

@testable import DistributedXPC
@testable import SwiftXPC

@XPCMarshal
enum SampleReplyError: Error, Equatable {
  case boom
}

private let sampleReplyMetadataTargetIdentifier = "replyError()"

@XPCService
distributed actor SampleReplyMetadataActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func replyError() throws(SampleReplyError) -> String {
    throw SampleReplyError.boom
  }
}

distributed actor SampleReplyActorWithoutMetadata {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func replyError() throws(SampleReplyError) -> String {
    throw SampleReplyError.boom
  }
}

@Test func DecodeReplyReturnsValue() throws {
  let envelope = XPCReplyEnvelope(kind: .returnValue, payload: try "pong".marshal())

  let value: String = try envelope.decodeReturnValue(
    throwing: SampleReplyError.self,
    returning: String.self
  )

  #expect(value == "pong")
}

@Test func DecodeReplyVoidAcceptsVoidEnvelope() throws {
  let envelope = XPCReplyEnvelope(kind: .returnVoid)

  try envelope.decodeReturnVoid(throwing: SampleReplyError.self)
}

@Test func DecodeReplyThrowsMarshalableError() throws {
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: try SampleReplyError.boom.marshal()
  )

  #expect(throws: SampleReplyError.boom) {
    let _: String = try envelope.decodeReturnValue(
      throwing: SampleReplyError.self,
      returning: String.self
    )
  }
}

@Test func DecodeReplyUsesFallbackThrownErrorType() throws {
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: try SampleReplyError.boom.marshal()
  )

  #expect(throws: SampleReplyError.boom) {
    let _: String = try envelope.decodeReturnValue(
      throwing: Error.self,
      returning: String.self,
      fallbackErrorType: SampleReplyError.self
    )
  }
}

@Test func DecodeReplyVoidUsesFallbackThrownErrorType() throws {
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: try SampleReplyError.boom.marshal()
  )

  #expect(throws: SampleReplyError.boom) {
    try envelope.decodeReturnVoid(
      throwing: Error.self,
      fallbackErrorType: SampleReplyError.self
    )
  }
}

@Test func DecodeReplyRejectsUnsupportedErasedErrorWithoutFallback() throws {
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: try SampleReplyError.boom.marshal()
  )

  #expect(throws: XPCRemoteCallError.unsupportedThrownErrorType("Error")) {
    let _: String = try envelope.decodeReturnValue(
      throwing: Error.self,
      returning: String.self
    )
  }
}

@Test func DecodeRemoteCallReplyUsesMetadataFallbackThrownErrorType() throws {
  let system = XPCDistributedActorSystem(connection: makeIdleConnection())
  _ = SampleReplyMetadataActor(actorSystem: system)
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: try SampleReplyError.boom.marshal()
  )

  #expect(throws: SampleReplyError.boom) {
    let _: String = try system.decodeRemoteCallReply(
      envelope,
      for: SampleReplyMetadataActor.self,
      target: RemoteCallTarget(sampleReplyMetadataTargetIdentifier),
      method: "replyError()",
      throwing: Error.self,
      returning: String.self
    )
  }
}

@Test func DecodeRemoteCallReplyDoesNotRequireMetadataForMarshalableError() throws {
  let system = XPCDistributedActorSystem(connection: makeIdleConnection())
  _ = SampleReplyActorWithoutMetadata(actorSystem: system)
  let envelope = XPCReplyEnvelope(
    kind: .throwError,
    payload: try SampleReplyError.boom.marshal()
  )

  #expect(throws: SampleReplyError.boom) {
    let _: String = try system.decodeRemoteCallReply(
      envelope,
      for: SampleReplyActorWithoutMetadata.self,
      target: RemoteCallTarget("missing"),
      method: "missing",
      throwing: SampleReplyError.self,
      returning: String.self
    )
  }
}

@Test func DecodeReplyRejectsUnexpectedKind() throws {
  let envelope = XPCReplyEnvelope(kind: .returnVoid)

  #expect(throws: XPCRemoteCallError.invalidReplyKind(expected: .returnValue, actual: .returnVoid))
  {
    let _: String = try envelope.decodeReturnValue(
      throwing: SampleReplyError.self,
      returning: String.self
    )
  }
}

@Test func ReplyEnvelopeWritesIntoDictionary() throws {
  var dictionary = XPCWireDictionary()
  let envelope = XPCReplyEnvelope(
    kind: .returnValue,
    payload: try "payload".marshal()
  )

  try envelope.write(to: &dictionary)
  let decoded = try XPCReplyEnvelope.unmarshal(from: dictionary.marshal())

  #expect(decoded.kind == .returnValue)
  #expect(try String.unmarshal(from: decoded.payload!) == "payload")
}

@Test func ReplyEnvelopeRoundTripsNullPayload() throws {
  // Optional.none 返回值经 onReturn 编码为 xpc_null 载荷;线缆往返后必须仍是
  // "有载荷且为 null",不得折叠成"无载荷"(否则客户端报 missingPayload)。
  let envelope = XPCReplyEnvelope(
    kind: .returnValue,
    payload: XPCObject(xpc_object: SwiftXPC.xpcNullCreate()))

  let decoded = try XPCReplyEnvelope.unmarshal(from: envelope.marshal())
  #expect(decoded.kind == .returnValue)
  #expect(decoded.payload != nil)
  #expect(SwiftXPC.xpcGetType(decoded.payload!.xpc_object) == SwiftXPC.xpcTypeNull)
}

@Test func ReplyEnvelopeRoundTripsAbsentPayload() throws {
  let envelope = XPCReplyEnvelope(kind: .returnVoid)

  let decoded = try XPCReplyEnvelope.unmarshal(from: envelope.marshal())
  #expect(decoded.kind == .returnVoid)
  #expect(decoded.payload == nil)
}
