// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import SwiftXPC

@Test func StructRoundTrip() async throws {
  let value = Greeting(id: 42, message: "hi", note: Optional<String>.none)
  let encoded = try value.marshal()
  let decoded = try Greeting.unmarshal(from: encoded)
  #expect(value == decoded)
}

@Test func XPCMarshalAccessLevels() async throws {
  let value = AccessControlledAggregate(
    publicValue: 1, internalValue: "two", filePrivateValue: 3.14, privateValue: true)
  let encoded = try value.marshal()
  let decoded = try AccessControlledAggregate.unmarshal(from: encoded)
  #expect(value == decoded)
}

@Test func XPCMarshalPropertyWrappers() async throws {
  var value = WrappedAggregate(title: "hello", percentage: 150)
  value.title = "world"  // verify setters run before marshal
  let encoded = try value.marshal()
  let decoded = try WrappedAggregate.unmarshal(from: encoded)
  #expect(decoded.title == "WORLD")
  #expect(decoded.percentage == 100)
  #expect(value == decoded)
}

@Test func XPCMarshalComputedPropertiesIgnored() async throws {
  let value = ComputedAggregate(first: "Ada", last: "Lovelace")
  let encoded = try value.marshal()
  let decoded = try ComputedAggregate.unmarshal(from: encoded)
  #expect(decoded.fullName == "Ada Lovelace")
  #expect(value == decoded)
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
  #expect(nested == decoded)
}
