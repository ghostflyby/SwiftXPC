// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import XPC

@testable import SwiftXPC

typealias XPCEquatable = XPCMarshal & Equatable

func roundTrip<T: XPCEquatable>(_ value: T) throws {
  let encoded = try value.marshal()
  let decoded = try T.unmarshal(from: encoded)
  assert(value == decoded)
}

/// Creates an activated, idle connection for in-process systems that never
/// carry XPC traffic. A never-activated connection traps in libxpc when its
/// last reference is released, so test-only systems must activate their dummies.
func makeIdleConnection() -> XPCConnection {
  let connection = XPCConnection(name: nil)
  connection.setEventHandler { _ in }
  connection.activate()
  return connection
}
