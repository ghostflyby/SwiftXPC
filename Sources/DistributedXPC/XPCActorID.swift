// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC

@XPCMarshal
public struct XPCActorID: Hashable, Sendable, Codable {
  public static let root = XPCActorID(id: 0)

  internal let id: UInt64
  public init(id: UInt64) { self.id = id }
}
