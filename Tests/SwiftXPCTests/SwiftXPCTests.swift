// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import SwiftXPC

@Test func Int() async throws {
  try test(1)
}

@Test func UInt() async throws {
  try test(UInt(1))
}

@Test func Double() async throws {
  try test(1.0)
}

@Test func array() async throws {
  try test([1, 2, 3])
}

@Test func Date() async throws {
  try test(Date.now)
}

@Test func UUID() async throws {
  try test(UUID())
}

@Test func String() async throws {
  try test("Hello, XPC!")
}

@Test func Dictionary() async throws {
  try test(["key": 1, "number": 42])
}

@Test func Data() async throws {
  try test("Hello, XPC!".data(using: .utf8))
}

@Test func OptionalString() async throws {
  try test(Optional<String>.some("Hello, XPC!"))
  try test(Optional<String>.none)
}

@Test func ArrayArray() async throws {
  try test([[1, 2, 3], [4, 5, 6]])
}

@Test func DictionaryArray() async throws {
  try test([["key1": 1], ["key2": 2]])
}

@Test func NestedDictionary() async throws {
  try test(["outerKey": ["innerKey": 1]])
}

@Test func UUIDDelicated() async throws {
  let xpc = try UUID.init().marshal()
  let xpcValue = XPCValue(xpc_object: xpc.xpc_object)
  guard case .UUID = xpcValue else {
    throw NSError(
      domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected XPCValue.UUID"])
  }
}

@Test func FileHandle() async throws {
  let original = FileHandle.standardOutput
  let v = try original.marshal()
  let decoded = try FileHandle.unmarshal(from: v)
  _ = decoded.fileDescriptor
}

typealias XPCEquatable = XPCMarshal & Equatable

func test<T: XPCEquatable>(_ _value: T) throws {
  let v = try _value.marshal()
  let d = try T.unmarshal(from: v)
  assert(_value == d)
}

@XPCMarshal
struct Greeting: Equatable {
  let id: Int
  let message: String
  let note: String?
}

@Test func XPCCodableMacroRoundTrip() async throws {
  let value = Greeting(id: 42, message: "hi", note: Optional<String>.none)
  let encoded = try value.marshal()
  let decoded = try Greeting.unmarshal(from: encoded)
  assert(value == decoded)
}
