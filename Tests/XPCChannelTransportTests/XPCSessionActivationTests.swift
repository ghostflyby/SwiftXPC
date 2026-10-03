// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import SwiftXPC

struct XPCSessionActivationTests {
  private final class WeakChannel: @unchecked Sendable {
    weak var value: XPCSessionChannel?
  }

  private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
      }
    }
  }

  @Test func SynchronousActivationCallbackCanCancelAndReenter() throws {
    let listener = XPCListener { request in
      request.reject(reason: "activation test")
    }
    defer { listener.cancel() }
    let box = WeakChannel()
    let activations = Mutex(0)
    let invalidations = Mutex(0)
    let channel = XPCSessionChannel(
      makingSession: { try XPCSession(endpoint: listener.endpoint, options: [.inactive]) },
      activateSession: { session in
        activations.withLock { $0 += 1 }
        try session.activate()
        // Model a native activation callback on the activating thread.
        box.value?.activate()
        box.value?.cancel()
      })
    box.value = channel
    channel.addInvalidationHandler { invalidations.withLock { $0 += 1 } }
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      channel.activate()
      finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 3) == .success)
    #expect(activations.withLock { $0 } == 1)
    #expect(invalidations.withLock { $0 } == 1)
    channel.activate()
    #expect(activations.withLock { $0 } == 1)
  }

  @Test func ConcurrentCancellationFinishesPendingSendDuringActivation() async throws {
    let listener = XPCListener { request in
      request.reject(reason: "activation test")
    }
    defer { listener.cancel() }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let channel = XPCSessionChannel(
      makingSession: { try XPCSession(endpoint: listener.endpoint, options: [.inactive]) },
      activateSession: { session in
        try session.activate()
        entered.signal()
        #expect(release.wait(timeout: .now() + 3) == .success)
      })
    DispatchQueue.global().async {
      channel.activate()
      finished.signal()
    }
    defer { release.signal(); channel.cancel() }
    #expect(await waitForSignal(entered))
    let send = Task { _ = try await channel.send(XPCDictionary().xpcObject) }
    // A second activation must leave the owner of native activation alone.
    channel.activate()
    channel.cancel()
    await #expect(throws: XPCChannelError.invalid) { try await send.value }
    await channel.waitForDisconnection()
    release.signal()
    #expect(await waitForSignal(finished))
    channel.activate()
    await #expect(throws: XPCChannelError.invalid) {
      _ = try await channel.send(XPCDictionary().xpcObject)
    }
  }

  @Test func SessionCreationFailureFinishesQueuedReplies() async throws {
    let channel = XPCSessionChannel(makingSession: { throw XPCChannelError.invalid })
    let send = Task { _ = try await channel.send(XPCDictionary().xpcObject) }
    channel.activate()
    await #expect(throws: XPCChannelError.invalid) { try await send.value }
    await channel.waitForDisconnection()
  }
}
