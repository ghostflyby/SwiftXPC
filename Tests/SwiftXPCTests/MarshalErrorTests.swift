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

@Test func NarrowIntegerRoundTrips() throws {
  #expect(try Int8.unmarshal(from: try Int8(-128).marshal()) == -128)
  #expect(try Int16.unmarshal(from: try Int16(-32768).marshal()) == -32768)
  #expect(try Int32.unmarshal(from: try Int32(Int32.max).marshal()) == Int32.max)
  #expect(try UInt8.unmarshal(from: try UInt8(255).marshal()) == 255)
  #expect(try UInt16.unmarshal(from: try UInt16(65535).marshal()) == 65535)
  #expect(try UInt32.unmarshal(from: try UInt32(UInt32.max).marshal()) == UInt32.max)
}

@Test func NarrowIntegerOverflowThrowsInsteadOfTrapping() throws {
  // A peer sending an out-of-range integer must surface as a typed error,
  // not a runtime trap that kills the process.
  #expect(throws: XPCMarshalError.self) {
    let _: Int8 = try Int8.unmarshal(from: 1000.marshal())
  }
  #expect(throws: XPCMarshalError.self) {
    let _: UInt8 = try UInt8.unmarshal(from: (-1).marshal())
  }
  #expect(throws: XPCMarshalError.self) {
    let _: Int32 = try Int32.unmarshal(from: (Int64(Int32.max) + 1).marshal())
  }
}

@Test func EmptyDataRoundTrips() throws {
  // Zero-length data must round-trip without dereferencing the NULL bytes
  // pointer that xpc_data_get_bytes_ptr returns for empty payloads.
  let decoded = try Data.unmarshal(from: try Data().marshal())
  #expect(decoded.isEmpty)
}

@Test func InvalidFileDescriptorThrowsInsteadOfTrapping() throws {
  // A closed descriptor makes xpc_fd_create return NULL; that must be a
  // typed error, not a force-unwrap crash.
  let pipe = Pipe()
  let closedFD = pipe.fileHandleForReading.fileDescriptor
  pipe.fileHandleForReading.closeFile()
  let invalid = FileHandle(fileDescriptor: closedFD, closeOnDealloc: false)
  #expect(throws: XPCMarshalError.self) {
    _ = try invalid.marshal()
  }
}
