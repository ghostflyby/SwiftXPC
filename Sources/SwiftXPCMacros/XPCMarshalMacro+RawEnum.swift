// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax

extension XPCMarshalMacro {
  static func encodeRawEnumFunction(for _: TypeSyntax, access: String) -> String {
    """
    \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> XPCObject {
      try self.rawValue.marshal()
    }
    """
  }

  static func decodeRawEnumFunction(
    for rawType: TypeSyntax,
    typeName: String,
    access: String
  ) -> String {
    """
    \(access)static func unmarshal(from object: XPCObject) throws(SwiftXPC.XPCMarshalError) -> Self {
      let rawValue = try \(rawType).unmarshal(from: object)
      guard let value = Self(rawValue: rawValue) else {
        throw SwiftXPC.XPCMarshalError.unknownEnumCase(
          String(describing: rawValue),
          enumName: \"\(typeName)\"
        )
      }
      return value
    }
    """
  }
}
