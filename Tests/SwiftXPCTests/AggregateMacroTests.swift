// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import XPC

@testable import SwiftXPC

@XPCMarshal
struct Greeting: Equatable {
  let id: Int
  let message: String
  let note: String?
}

@propertyWrapper
struct Uppercased: Equatable {
  private var storage: String
  var wrappedValue: String {
    get { storage }
    set { storage = newValue.uppercased() }
  }

  init(wrappedValue: String) { storage = wrappedValue.uppercased() }
}

@propertyWrapper
struct Clamped<Value: Comparable & Equatable>: Equatable {
  private var storage: Value
  private let range: ClosedRange<Value>

  var wrappedValue: Value {
    get { storage }
    set { storage = min(max(newValue, range.lowerBound), range.upperBound) }
  }

  init(wrappedValue: Value, _ range: ClosedRange<Value>) {
    self.range = range
    storage = min(max(wrappedValue, range.lowerBound), range.upperBound)
  }
}

@XPCMarshal
struct AccessControlledAggregate: Equatable {
  public let publicValue: Int
  let internalValue: String
  fileprivate let filePrivateValue: Double
  private let privateValue: Bool

  init(publicValue: Int, internalValue: String, filePrivateValue: Double, privateValue: Bool) {
    self.publicValue = publicValue
    self.internalValue = internalValue
    self.filePrivateValue = filePrivateValue
    self.privateValue = privateValue
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.publicValue == rhs.publicValue && lhs.internalValue == rhs.internalValue
      && lhs.filePrivateValue == rhs.filePrivateValue && lhs.privateValue == rhs.privateValue
  }
}

@XPCMarshal
struct WrappedAggregate: Equatable {
  @Uppercased var title: String = ""
  @Clamped(0...100) var percentage: Int = 0

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title && lhs.percentage == rhs.percentage
  }
}

@XPCMarshal
struct ComputedAggregate: Equatable {
  var first: String
  var last: String
  var fullName: String { "\(first) \(last)" }  // computed property should be ignored by macro
}

@XPCMarshal
struct NestedAggregate: Equatable {
  var payload: Greeting
  var notes: [Greeting?]
  var metadata: [String: Greeting]
}

@XPCMarshal
enum JobState: Equatable {
  case idle
  case progress(percent: Int)
  case message(String)
  case compound(title: String, retries: Int)
  case tuple(String, Int)
}

@Test func XPCCodableMacroRoundTrip() async throws {
  let value = Greeting(id: 42, message: "hi", note: Optional<String>.none)
  let encoded = try value.marshal()
  let decoded = try Greeting.unmarshal(from: encoded)
  assert(value == decoded)
}

@Test func XPCMarshalAccessLevels() async throws {
  let value = AccessControlledAggregate(
    publicValue: 1, internalValue: "two", filePrivateValue: 3.14, privateValue: true)
  let encoded = try value.marshal()
  let decoded = try AccessControlledAggregate.unmarshal(from: encoded)
  assert(value == decoded)
}

@Test func XPCMarshalPropertyWrappers() async throws {
  var value = WrappedAggregate(title: "hello", percentage: 150)
  value.title = "world"  // verify setters run before marshal
  let encoded = try value.marshal()
  let decoded = try WrappedAggregate.unmarshal(from: encoded)
  assert(decoded.title == "WORLD")
  assert(decoded.percentage == 100)
  assert(value == decoded)
}

@Test func XPCMarshalComputedPropertiesIgnored() async throws {
  let value = ComputedAggregate(first: "Ada", last: "Lovelace")
  let encoded = try value.marshal()
  let decoded = try ComputedAggregate.unmarshal(from: encoded)
  assert(decoded.fullName == "Ada Lovelace")
  assert(value == decoded)
}

@Test func XPCMarshalNestedAggregates() async throws {
  let nested = NestedAggregate(
    payload: Greeting(id: 7, message: "hi", note: "nested"),
    notes: [Greeting(id: 1, message: "a", note: nil), nil],
    metadata: [
      "first": Greeting(id: 2, message: "b", note: "note"),
      "second": Greeting(id: 3, message: "c", note: nil),
    ]
  )
  let encoded = try nested.marshal()
  let decoded = try NestedAggregate.unmarshal(from: encoded)
  assert(nested == decoded)
}

@Test func XPCMarshalEnumRoundTrip() async throws {
  try roundTrip(JobState.idle)
  try roundTrip(JobState.progress(percent: 10))
  try roundTrip(JobState.message("hello"))
  try roundTrip(JobState.compound(title: "retry", retries: 3))
  try roundTrip(JobState.tuple("pair", 2))
}
