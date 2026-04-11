// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
@testable import DistributedXPC
import SwiftXPC
import Testing

@available(macOS 15, *)
@XPCMarshal
enum SampleReplyError: Error, Equatable {
  case boom
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

@Test func DecodeReplyRejectsUnexpectedKind() throws {
  guard #available(macOS 15, *) else {
    return
  }
  let envelope = XPCReplyEnvelope(kind: .returnVoid)

  #expect(throws: XPCRemoteCallError.invalidReplyKind(expected: .returnValue, actual: .returnVoid)) {
    let _: String = try envelope.decodeReturnValue(
      throwing: SampleReplyError.self,
      returning: String.self
    )
  }
}
