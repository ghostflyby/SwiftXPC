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
