// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import SwiftXPC

@XPCMarshal
final class FinalGreeting: Equatable {
  let id: Int
  let message: String
  let note: String?

  init(id: Int, message: String, note: String?) {
    self.id = id
    self.message = message
    self.note = note
  }

  static func == (lhs: FinalGreeting, rhs: FinalGreeting) -> Bool {
    lhs.id == rhs.id && lhs.message == rhs.message && lhs.note == rhs.note
  }
}

@Test func FinalClassRoundTrip() async throws {
  let value = FinalGreeting(id: 1, message: "hello", note: nil)
  let encoded = try value.marshal()
  let decoded = try FinalGreeting.unmarshal(from: encoded)
  assert(value == decoded)
}
