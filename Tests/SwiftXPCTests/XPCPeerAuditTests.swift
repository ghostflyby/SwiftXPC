// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
@testable import DistributedXPC
import Security
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@available(macOS 15, *)
@XPCService
distributed actor AuditRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "root"
  }
}

/// The code signing identifier of the running test executable, or nil when
/// the Security API does not provide one.
private func ownSigningIdentifier() -> String? {
  var code: SecCode?
  guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
  var staticCode: SecStaticCode?
  guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
    return nil
  }
  var info: CFDictionary?
  guard
    SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
    let info
  else { return nil }
  return (info as NSDictionary)[kSecCodeInfoIdentifier as String] as? String
}

private func waitUntil(
  deadline: ContinuousClock.Instant = .now + .seconds(2),
  _ condition: () -> Bool
) async -> Bool {
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

// MARK: - Server-side requirement installation

@Test func MalformedRequirementRejectsPeerBeforeAudit() async throws {
  guard #available(macOS 15, *) else { return }
  let auditCalls = Mutex<Int>(0)
  let rejections = Mutex<[(any Error)?]>([])
  let channel = try RootChannel(
    AuditRoot.self,
    peerCodeSigningRequirement: "not a code signing requirement !!",
    shouldAccept: { _ in
      auditCalls.withLock { $0 += 1 }
      return true
    },
    onPeerReject: { _, error in
      rejections.withLock { $0.append(error) }
    })
  let root = try AuditRoot.connect(using: channel.client)

  await #expect(throws: XPCConnection.ConnectionError.self) {
    _ = try await root.ping()
  }
  #expect(await waitUntil { !rejections.withLock { $0 }.isEmpty })
  // The requirement install failure must preempt the audit hook and surface
  // as a PeerRequirementError (fail-closed, no silent degradation).
  #expect(auditCalls.withLock { $0 } == 0)
  let rejectionsSeen = rejections.withLock { $0 }
  #expect(rejectionsSeen.count == 1)
  #expect(rejectionsSeen.first is XPCConnection.PeerRequirementError)
}

@Test func UnsatisfiableRequirementDropsPeerAtActivation() async throws {
  guard #available(macOS 15, *) else { return }
  let accepted = Mutex<Int>(0)
  let rejections = Mutex<[(any Error)?]>([])
  let ends = Mutex<Int>(0)
  let channel = try RootChannel(
    AuditRoot.self,
    peerCodeSigningRequirement: "identifier \"com.example.definitely.not.us\"",
    onPeerAccept: { _ in accepted.withLock { $0 += 1 } },
    onPeerEnd: { _ in ends.withLock { $0 += 1 } },
    onPeerReject: { _, error in
      rejections.withLock { $0.append(error) }
    })
  let root = try AuditRoot.connect(using: channel.client)

  // The requirement installs cleanly; the kernel drops the peer when the
  // signature fails at activation, which surfaces server-side as a peer end.
  await #expect(throws: XPCConnection.ConnectionError.self) {
    _ = try await root.ping()
  }
  #expect(await waitUntil { ends.withLock { $0 } >= 1 })
  #expect(accepted.withLock { $0 } == 1)
  #expect(rejections.withLock { $0 }.isEmpty)
}

@Test func MatchingRequirementAllowsRootCalls() async throws {
  guard #available(macOS 15, *) else { return }
  guard let identifier = ownSigningIdentifier() else {
    Issue.record("Could not determine the test binary's code signing identifier")
    return
  }
  let channel = try RootChannel(
    AuditRoot.self,
    peerCodeSigningRequirement: "identifier \"\(identifier)\"")
  let root = try AuditRoot.connect(using: channel.client)

  #expect(try await root.ping() == "root")
}

// MARK: - shouldAccept hook semantics

@Test func ThrowingShouldAcceptRejectsPeerWithError() async throws {
  guard #available(macOS 15, *) else { return }
  struct AuditHookFailure: Error {}
  let rejections = Mutex<[(any Error)?]>([])
  let channel = try RootChannel(
    AuditRoot.self,
    shouldAccept: { _ in throw AuditHookFailure() },
    onPeerReject: { _, error in
      rejections.withLock { $0.append(error) }
    })
  let root = try AuditRoot.connect(using: channel.client)

  await #expect(throws: XPCConnection.ConnectionError.self) {
    _ = try await root.ping()
  }
  #expect(await waitUntil { !rejections.withLock { $0 }.isEmpty })
  let rejectionsSeen = rejections.withLock { $0 }
  #expect(rejectionsSeen.count == 1)
  #expect(rejectionsSeen.first is AuditHookFailure)
}

@Test func ShouldAcceptFalseReportsNilError() async throws {
  guard #available(macOS 15, *) else { return }
  let rejections = Mutex<[(any Error)?]>([])
  let channel = try RootChannel(
    AuditRoot.self,
    shouldAccept: { _ in false },
    onPeerReject: { _, error in
      rejections.withLock { $0.append(error) }
    })
  let root = try AuditRoot.connect(using: channel.client)

  await #expect(throws: XPCConnection.ConnectionError.self) {
    _ = try await root.ping()
  }
  #expect(await waitUntil { !rejections.withLock { $0 }.isEmpty })
  let rejectionsSeen = rejections.withLock { $0 }
  #expect(rejectionsSeen.count == 1)
  // Element type is (any Error)?; unwrap the array's outer optional first so
  // the comparison targets the recorded error itself.
  guard let recorded = rejectionsSeen.first else {
    Issue.record("Expected exactly one rejection")
    return
  }
  #expect(recorded == nil)
}

// MARK: - Client-side service authentication

@Test func MatchingClientRequirementAllowsRootCalls() async throws {
  guard #available(macOS 15, *) else { return }
  guard let identifier = ownSigningIdentifier() else {
    Issue.record("Could not determine the test binary's code signing identifier")
    return
  }
  let channel = try RootChannel(AuditRoot.self)
  let root = try AuditRoot.connect(
    using: channel.client,
    peerCodeSigningRequirement: "identifier \"\(identifier)\"")

  #expect(try await root.ping() == "root")
}

@Test func UnsatisfiableClientRequirementRejectsService() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(AuditRoot.self)
  let root = try AuditRoot.connect(
    using: channel.client,
    peerCodeSigningRequirement: "identifier \"com.example.definitely.not.us\"")

  // The kernel delivers the requirement failure through the reply path; send
  // surfaces it as the typed connection error.
  await #expect(throws: XPCConnection.ConnectionError.peerCodeSigningRequirement) {
    _ = try await root.ping()
  }
}
