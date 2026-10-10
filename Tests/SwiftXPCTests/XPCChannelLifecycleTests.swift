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

@Test func SendCancellationCompletesWhileReplyResumptionIsSuspended() async {
  // The callback claims its outcome, then pauses before resuming the task.
  // Concurrent Task.cancel must complete; it cannot wait on a lock retained by
  // resumption. A child watchdog bounds failures of the old locking strategy.
  await #expect(processExitsWith: .success) {
    // All signal waits share one budget, leaving two seconds for the watchdog.
    let deadline = DispatchTime.now() + 8
    DispatchQueue.global().asyncAfter(deadline: deadline + 2) { exit(77) }
    let installed = DispatchSemaphore(value: 0), delivery = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
    let sink = XPCSendSink(beforeResume: {
      delivery.signal()
      guard release.wait(timeout: deadline) == .success else { exit(1) }
    })
    let task = Task {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          sink.install($0)
          installed.signal()
        }
      } onCancel: {
        sink.finish(.failure(CancellationError()))
      }
    }
    guard await waitForTestSignal(installed, until: deadline) else { exit(1) }
    DispatchQueue.global().async { sink.finish(.failure(XPCChannelError.invalid)) }
    guard await waitForTestSignal(delivery, until: deadline) else { exit(1) }
    DispatchQueue.global().async {
      task.cancel()
      cancelled.signal()
    }
    guard await waitForTestSignal(cancelled, until: deadline) else { exit(1) }
    release.signal()
    do {
      _ = try await task.value
      exit(1)
    } catch let error as XPCChannelError where error == .invalid {
      // The earlier callback won; cancellation does not replace its outcome.
    } catch { exit(1) }
    exit(0)
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
