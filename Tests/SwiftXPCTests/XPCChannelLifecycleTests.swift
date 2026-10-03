// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
@testable import SwiftXPC
import Testing

@Test func FirstSendOutcomeWinsBeforeContinuationInstallation() async throws {
  let sink = XPCSendSink()
  sink.finish(.failure(CancellationError()))
  sink.finish(.reply(SendableXPCObject(xpc_dictionary_create(nil, nil, 0))))
  await #expect(throws: CancellationError.self) {
    _ = try await withCheckedThrowingContinuation { sink.install($0) }
  }
}

@Test func IncomingMessageCopiesShareOneReplyCapability() {
  let replies = Mutex(0)
  let payload = SendableXPCObject(xpc_dictionary_create(nil, nil, 0))
  let message = XPCIncomingMessage(payload: payload.raw) { _ in replies.withLock { $0 += 1 } }
  let copy = message
  DispatchQueue.concurrentPerform(iterations: 64) { _ in copy.reply(payload.raw) }
  #expect(replies.withLock { $0 } == 1)
}

@Test(arguments: XPCChannelTransport.allCases)
func DialRejectsMalformedEndpoint(transport: XPCChannelTransport) {
  #expect(throws: XPCMarshalError.self) {
    _ = try transport.channel(dialing: xpc_dictionary_create(nil, nil, 0))
  }
}
