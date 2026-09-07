// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import XPC

@testable import SwiftXPC

@Test func DecodeMissingRequiredKey() throws {
  var dict = SwiftXPC.XPCDictionary()
  // Set "id" but not the required "message" key.
  dict["id"] = try 1.marshal()
  #expect(throws: XPCMarshalError.self) {
    let _: Greeting = try Greeting.unmarshal(from: dict.marshal())
  }
}

@Test func DecodeTypeMismatch() throws {
  let int = try 42.marshal()
  #expect(throws: XPCMarshalError.self) {
    let _: String = try String.unmarshal(from: int)
  }
}

@Test func DecodeUnknownEnumCase() throws {
  var dict = SwiftXPC.XPCDictionary()
  dict["case"] = XPCObject(xpc_object: xpc_string_create("bogus"))
  #expect(throws: XPCMarshalError.self) {
    let _: JobState = try JobState.unmarshal(from: dict.marshal())
  }
}

@Test func DecodeNullForNonOptionalType() throws {
  let nullObj = XPCObject(xpc_object: xpc_null_create())
  #expect(throws: XPCMarshalError.self) {
    let _: String = try String.unmarshal(from: nullObj)
  }
}
