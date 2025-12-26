// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax

extension XPCMarshalMacro {
  static func encodeEnumFunction(for cases: [EnumCase], access: String) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case .\(enumCase.name):
            array.append(SwiftXPC.XPCObject(xpc_object: SwiftXPC.xpcStringCreate(\"\(enumCase.name)\")))
          """
      }

      let bindingList = enumCase.associatedValues.map { "let \($0.binding)" }.joined(
        separator: ", ")
      let allUnlabeled = enumCase.associatedValues.allSatisfy { $0.label == nil }
      let payloadAssignments = enumCase.associatedValues.map { value in
        let target = allUnlabeled ? "array" : "payload"
        return """
          \(target).append(try \(value.binding).marshal())
          """
      }.joined(separator: "\n")
      let payloadEncoding: String
      if allUnlabeled {
        payloadEncoding = payloadAssignments
      } else {
        payloadEncoding = """
            var payload = SwiftXPC.XPCArray()
          \(payloadAssignments)
            array.append(SwiftXPC.XPCObject(xpc_object: payload.xpc_object))
          """
      }

      return """
        case .\(enumCase.name)(\(bindingList)):
          array.append(SwiftXPC.XPCObject(xpc_object: SwiftXPC.xpcStringCreate(\"\(enumCase.name)\")))
          \(payloadEncoding)
        """
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> XPCObject {
        var array = SwiftXPC.XPCArray()
        switch self {
        \(caseBranches)
        }
        return SwiftXPC.XPCObject(xpc_object: array.xpc_object)
      }
      """
  }

  static func decodeEnumFunction(
    for cases: [EnumCase],
    typeName: String,
    access: String
  ) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case \"\(enumCase.name)\":
            return .\(enumCase.name)
          """
      }

      let allUnlabeled = enumCase.associatedValues.allSatisfy { $0.label == nil }
      let valuesDecoding = enumCase.associatedValues.enumerated().map { index, value in
        let binding = value.binding
        let source = allUnlabeled ? "array" : "payloadArray"
        let offset = allUnlabeled ? 1 : 0
        return """
            let raw_\(binding) = \(source)[\(index + offset)]
            let \(binding) = try \(value.type).unmarshal(from: raw_\(binding))
          """
      }.joined(separator: "\n")
      let argumentList = enumCase.associatedValues.map { value in
        if let label = value.label {
          return "\(label): \(value.binding)"
        } else {
          return value.binding
        }
      }.joined(separator: ", ")
      return """
        case \"\(enumCase.name)\":
          \(allUnlabeled ? "" : "  let payloadPtr = array[1]\n  let payloadType = SwiftXPC.xpcGetType(payloadPtr.xpc_object)\n  guard payloadType == SwiftXPC.xpcTypeArray else {\n    throw SwiftXPC.XPCMarshalError.typeMismatch(\n      expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeArray)),\n      actual: String(cString: SwiftXPC.xpcTypeGetName(payloadType))\n    )\n  }\n  let payloadArray = SwiftXPC.XPCArray(xpc_object: payloadPtr.xpc_object)\n")
          \(valuesDecoding)
          return .\(enumCase.name)(\(argumentList))
        """
    }.joined(separator: "\n")

    return """
      \(access)static func unmarshal(from object: XPCObject) throws(SwiftXPC.XPCMarshalError) -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeArray else {
          throw SwiftXPC.XPCMarshalError.typeMismatch(
            expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeArray)),
            actual: String(cString: SwiftXPC.xpcTypeGetName(type))
          )
        }
        let array = SwiftXPC.XPCArray(xpc_object: object.xpc_object)
        let casePtr = array[0]
        let caseName = try String.unmarshal(from: casePtr)

        switch caseName {
        \(caseBranches)
        default:
          throw SwiftXPC.XPCMarshalError.unknownEnumCase(caseName, enumName: \"\(typeName)\")
        }
      }
      """
  }
}
