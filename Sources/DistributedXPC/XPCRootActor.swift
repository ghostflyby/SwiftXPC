// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC

/// The bootstrap actor type constructed once per actor service.
/// All accepted channels on that service bind to the same root instance.
public protocol XPCRootActor: XPCExportableActor,
  XPCDistributedTargetMetadataProviding
{}

extension XPCRootActor {
  /// Connects to an XPC service by bundle identifier, such as an embedded `.xpc` bundle.
  /// Use `XPCRootConnection` for lifecycle observation, explicit close, or retries.
  public static func connect(
    toService serviceName: String, transport: XPCChannelTransport = .cConnection
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(toService: serviceName, transport: transport).root
  }

  /// Connects to a name advertised in a launchd job's `MachServices` dictionary.
  /// Use `XPCRootConnection` for lifecycle observation, explicit close, or retries.
  public static func connect(
    machService serviceName: String, transport: XPCChannelTransport = .cConnection
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(machService: serviceName, transport: transport).root
  }

  public static func connect(using channel: XPCChannel) throws -> Self {
    try XPCRootConnection<Self>.connect(using: channel).root
  }

  /// Native C authentication, before activation and channel adoption.
  public static func connect(
    using connection: XPCConnection, peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(
      using: connection, peerCodeSigningRequirement: peerCodeSigningRequirement
    ).root
  }
}
