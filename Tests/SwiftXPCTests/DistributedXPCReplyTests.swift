// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC
import Testing
import Synchronization

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

@XPCService
distributed actor CancellationReplyRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func cancelValue() throws -> String {
    withUnsafeCurrentTask { $0?.cancel() }
    try Task.checkCancellation()
    return "unreachable"
  }

  distributed func cancelVoid() throws {
    withUnsafeCurrentTask { $0?.cancel() }
    try Task.checkCancellation()
  }

  distributed func ping() -> String { "alive" }
}

@Test(arguments: XPCChannelTransport.allCases, [false, true])
func ServiceTaskCancellationReachesCaller(
  transport: XPCChannelTransport, returningVoid: Bool
) async throws {
  let service = try xpcTest(
    CancellationReplyRoot.self, transport: transport, watchdog: .seconds(10))
  defer { service.close() }
  await #expect(throws: CancellationError.self) {
    if returningVoid {
      try await service.client.root.cancelVoid()
    } else {
      _ = try await service.client.root.cancelValue()
    }
  }
  // Cancelling one invocation must not terminate its channel or the next task.
  #expect(try await service.client.root.ping() == "alive")
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
  let system = XPCDistributedActorSystem()
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
  let system = XPCDistributedActorSystem()
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

@Test func ReplyEnvelopeRoundTripsNullPayload() throws {
  // Optional.none 返回值经 onReturn 编码为 xpc_null 载荷;线缆往返后必须仍是
  // "有载荷且为 null",不得折叠成"无载荷"(否则客户端报 missingPayload)。
  let envelope = XPCReplyEnvelope(
    kind: .returnValue,
    payload: xpc_null_create())

  let decoded = try XPCReplyEnvelope.unmarshal(from: envelope.marshal())
  #expect(decoded.kind == .returnValue)
  #expect(decoded.payload != nil)
  #expect(xpc_get_type(decoded.payload!) == XPC_TYPE_NULL)
}

@Test func ReplyEnvelopeRoundTripsAbsentPayload() throws {
  let envelope = XPCReplyEnvelope(kind: .returnVoid)

  let decoded = try XPCReplyEnvelope.unmarshal(from: envelope.marshal())
  #expect(decoded.kind == .returnVoid)
  #expect(decoded.payload == nil)
}

private enum UnencodableReplyError: Error, XPCMarshal {
  case failure
  func marshal() throws(XPCMarshalError) -> xpc_object_t {
    throw .missingKey("intentional encoding failure")
  }
  static func unmarshal(from object: xpc_object_t) throws(XPCMarshalError) -> Self { .failure }
}

@Test func ErrorEncodingFailureStillCompletesReply() throws {
  let replies = Mutex<[SendableXPCObject]>([])
  let message = XPCIncomingMessage(payload: XPCDictionary().xpcObject) { reply in
    replies.withLock { $0.append(SendableXPCObject(reply)) }
  }
  XPCDistributedActorSystem().replyToFailure(UnencodableReplyError.failure, message: message)
  #expect(replies.withLock { $0.count } == 1)
  let raw = try #require(replies.withLock { $0.first })
  let envelope = try XPCReplyEnvelope.unmarshal(from: raw.raw)
  #expect(envelope.kind == .throwError)
  #expect(throws: XPCRemoteCallError.missingPayload(.throwError)) {
    try envelope.decodeReturnVoid(throwing: UnencodableReplyError.self)
  }
}

@Test func NonmarshalableFailureStillCompletesReply() throws {
  struct PlainFailure: Error {}
  let replies = Mutex<[SendableXPCObject]>([])
  let message = XPCIncomingMessage(payload: XPCDictionary().xpcObject) { reply in
    replies.withLock { $0.append(SendableXPCObject(reply)) }
  }
  XPCDistributedActorSystem().replyToFailure(PlainFailure(), message: message)
  let raw = try #require(replies.withLock { $0.first })
  let envelope = try XPCReplyEnvelope.unmarshal(from: raw.raw)
  let error = try XPCDispatchError.unmarshal(from: #require(envelope.payload))
  guard case .targetExecutionFailed = error else {
    Issue.record("Unexpected fallback error: \(error)")
    return
  }
}

@Test func CancellationFailureStillCompletesReply() throws {
  let replies = Mutex<[SendableXPCObject]>([])
  let message = XPCIncomingMessage(payload: XPCDictionary().xpcObject) { reply in
    replies.withLock { $0.append(SendableXPCObject(reply)) }
  }
  XPCDistributedActorSystem().replyToFailure(CancellationError(), message: message)
  #expect(replies.withLock { $0.count } == 1)
  let raw = try #require(replies.withLock { $0.first })
  let envelope = try XPCReplyEnvelope.unmarshal(from: raw.raw)
  #expect(envelope.kind == .cancelled)
  #expect(envelope.payload == nil)
  #expect(throws: CancellationError.self) {
    let _: String = try envelope.decodeReturnValue(
      throwing: SampleReplyError.self, returning: String.self,
      fallbackErrorType: SampleReplyError.self)
  }
  #expect(throws: CancellationError.self) {
    try envelope.decodeReturnVoid(
      throwing: SampleReplyError.self, fallbackErrorType: SampleReplyError.self)
  }
}
