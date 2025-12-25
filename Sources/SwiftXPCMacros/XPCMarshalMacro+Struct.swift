// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax

extension XPCMarshalMacro {
  static func decodeFunction(
    for properties: [Property],
    typeName _: String,
    access: String
  ) -> String {
    let bindings = properties.map { property in
      let key = property.name
      let rawPtr = "rawPtr_\(key)"
      if property.isOptional {
        return """
          let \(key): \(property.type)
          if let \(rawPtr) = SwiftXPC.xpcDictionaryGetValue(dict, "\(key)") {
            if SwiftXPC.xpcGetType(\(rawPtr)) == SwiftXPC.xpcTypeNull {
              \(key) = nil
            } else {
              \(key) = try .unmarshal(from: SwiftXPC.XPCObject(xpc_object: \(rawPtr)))
            }
          } else {
            \(key) = nil
          }
          """
      } else {
        return """
          let \(key): \(property.type)
          guard let \(rawPtr) = SwiftXPC.xpcDictionaryGetValue(dict, "\(key)") else {
            throw SwiftXPC.XPCMarshalError.missingKey("\(key)")
          }
          \(key) = try .unmarshal(from: SwiftXPC.XPCObject(xpc_object: \(rawPtr)))
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      \(access)static func unmarshal(from object: XPCObject) throws(SwiftXPC.XPCMarshalError) -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeDictionary else {
          throw SwiftXPC.XPCMarshalError.typeMismatch(
            expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeDictionary)),
            actual: String(cString: SwiftXPC.xpcTypeGetName(type))
          )
        }
        let dict = object.xpc_object
        \(bindings)
        return Self.init(\(arguments))
      }
      """
  }

  static func decodeFrozenStructFunction(
    for properties: [Property],
    typeName _: String,
    access: String
  ) -> String {
    let bindings = properties.enumerated().map { index, property in
      let rawPtr = "rawPtr_\(property.name)"
      if property.isOptional {
        return """
          let \(property.name): \(property.type)
          let \(rawPtr) = SwiftXPC.xpcArrayGetValue(array, \(index))
          if SwiftXPC.xpcGetType(\(rawPtr)) == SwiftXPC.xpcTypeNull {
            \(property.name) = nil
          } else {
            \(property.name) = try .unmarshal(from: SwiftXPC.XPCObject(xpc_object: \(rawPtr)))
          }
          """
      } else {
        return """
          let \(property.name): \(property.type)
          let \(rawPtr) = SwiftXPC.xpcArrayGetValue(array, \(index))
          \(property.name) = try .unmarshal(from: SwiftXPC.XPCObject(xpc_object: \(rawPtr)))
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      \(access)static func unmarshal(from object: XPCObject) throws(SwiftXPC.XPCMarshalError) -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeArray else {
          throw SwiftXPC.XPCMarshalError.typeMismatch(
            expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeArray)),
            actual: String(cString: SwiftXPC.xpcTypeGetName(type))
          )
        }
        let array = object.xpc_object
        let count = SwiftXPC.xpcArrayGetCount(array)
        guard count >= \(properties.count) else {
          throw SwiftXPC.XPCMarshalError.missingKey(\"\(properties.count - 1)\")
        }
        \(bindings)
        return Self.init(\(arguments))
      }
      """
  }

  static func encodeFrozenStructFunction(for properties: [Property], access: String) -> String {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            SwiftXPC.xpcArrayAppendValue(array, try value.marshal().xpc_object)
          } else {
            SwiftXPC.xpcArrayAppendValue(array, SwiftXPC.xpcNullCreate())
          }
          """
      } else {
        return """
          SwiftXPC.xpcArrayAppendValue(array, try self.\(property.name).marshal().xpc_object)
          """
      }
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> XPCObject {
        let array = SwiftXPC.xpcArrayCreate(nil, 0)
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: array)
      }
      """
  }

  static func encodeFunction(for properties: [Property], access: String) -> String {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            SwiftXPC.xpcDictionarySetValue(dict, \"\(property.name)\", try value.marshal().xpc_object)
          } else {
            SwiftXPC.xpcDictionarySetValue(dict, \"\(property.name)\", SwiftXPC.xpcNullCreate())
          }
          """
      } else {
        return """
          SwiftXPC.xpcDictionarySetValue(dict, \"\(property.name)\", try self.\(property.name).marshal().xpc_object)
          """
      }
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> XPCObject {
        let dict = SwiftXPC.xpcDictionaryCreate(nil, nil, 0)
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: dict)
      }
      """
  }
}
