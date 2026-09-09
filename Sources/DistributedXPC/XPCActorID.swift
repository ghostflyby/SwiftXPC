// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC

@XPCMarshal
@available(macOS 13.0, *)
public struct XPCActorID: Hashable, Sendable, Codable, Equatable {
  public static let root = XPCActorID(id: 0)

  internal let id: UInt64
  public init(id: UInt64) { self.id = id }
}

