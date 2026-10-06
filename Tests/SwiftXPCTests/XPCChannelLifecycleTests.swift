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

private final class CancelSessionOnDeinit: @unchecked Sendable {
  weak var channel: XPCChannel?

  init(_ channel: XPCChannel) { self.channel = channel }

  deinit { channel?.cancel() }
}

private func verifySessionHandlerRelease(replacing: Bool) {
  // Run in a child process so a recursive-lock abort or hang fails this test alone.
  DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(77) }
  let channel = XPCChannel(
    session: XPCSessionChannel(makingSession: { throw XPCChannelError.invalid }))
  let invalidations = Mutex(0)
  channel.addInvalidationHandler { invalidations.withLock { $0 += 1 } }
  weak var captured: CancelSessionOnDeinit?
  do {
    let cleanup = CancelSessionOnDeinit(channel)
    captured = cleanup
    channel.setIncomingHandler { [cleanup] _ in withExtendedLifetime(cleanup) {} }
  }
  if replacing {
    channel.setIncomingHandler { _ in }
  } else {
    channel.cancel()
  }
  guard captured == nil, invalidations.withLock({ $0 }) == 1 else { exit(1) }
  channel.cancel()
  guard invalidations.withLock({ $0 }) == 1 else { exit(1) }
  exit(0)
}

@Test func SessionCancellationReleasesIncomingHandlerOutsideLock() async {
  await #expect(processExitsWith: .success) {
    verifySessionHandlerRelease(replacing: false)
  }
}

@Test func SessionHandlerReplacementReleasesPreviousHandlerOutsideLock() async {
  await #expect(processExitsWith: .success) {
    verifySessionHandlerRelease(replacing: true)
  }
}
