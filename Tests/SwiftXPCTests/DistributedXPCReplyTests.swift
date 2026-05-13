// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC
import Testing

@testable import DistributedXPC

@available(macOS 15, *)
@XPCMarshal
enum SampleReplyError: Error, Equatable {
  case boom
}

@available(macOS 15, *)
private let sampleReplyMetadataTargetIdentifier = "replyError()"

@available(macOS 15, *)
@XPCService
distributed actor SampleReplyMetadataActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func replyError() throws(SampleReplyError) -> String {
    throw SampleReplyError.boom
  }
}

@available(macOS 15, *)
extension SampleReplyMetadataActor: XPCDefaultActorInitializable {}

@available(macOS 15, *)
distributed actor SampleReplyActorWithoutMetadata {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func replyError() throws(SampleReplyError) -> String {
    throw SampleReplyError.boom
  }
}

@Test func DecodeReplyReturnsValue() throws {
  guard #available(macOS 15, *) else {
    return
  }
  let envelope = XPCReplyEnvelope(kind: .returnValue, payload: try "pong".marshal())

  let value: String = try envelope.decodeReturnValue(
    throwing: SampleReplyError.self,
    returning: String.self
  )

  #expect(value == "pong")
}

@Test func DecodeReplyVoidAcceptsVoidEnvelope() throws {
  guard #available(macOS 15, *) else {
    return
  }
  let envelope = XPCReplyEnvelope(kind: .returnVoid)

  try envelope.decodeReturnVoid(throwing: SampleReplyError.self)
}

@Test func DecodeReplyThrowsMarshalableError() throws {
  guard #available(macOS 15, *) else {
    return
  }
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
  guard #available(macOS 15, *) else {
    return
  }
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
  guard #available(macOS 15, *) else {
    return
  }
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
  guard #available(macOS 15, *) else {
    return
  }
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
  guard #available(macOS 15, *) else {
    return
  }
  let system = XPCDistributedActorSystem(connection: XPCConnection(name: nil))
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
  guard #available(macOS 15, *) else {
    return
  }
  let system = XPCDistributedActorSystem(connection: XPCConnection(name: nil))
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
  guard #available(macOS 15, *) else {
    return
  }
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
  guard #available(macOS 15, *) else {
    return
  }
  var dictionary = XPCDictionary()
  let envelope = XPCReplyEnvelope(
    kind: .returnValue,
    payload: try "payload".marshal()
  )

  try envelope.write(to: &dictionary)
  let decoded = try XPCReplyEnvelope.unmarshal(from: dictionary.marshal())

  #expect(decoded.kind == .returnValue)
  #expect(try String.unmarshal(from: decoded.payload!) == "payload")
}
