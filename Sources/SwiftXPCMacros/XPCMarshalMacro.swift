// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import XPC

@main
struct SwiftXPCPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [XPCMarshalMacro.self]
}

public struct XPCMarshalMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let marshalImpl: String
    let unmarshalImpl: String

    if let structDecl = declaration.as(StructDeclSyntax.self) {
      let properties = storedProperties(in: structDecl)
      marshalImpl = encodeFunction(for: properties)
      unmarshalImpl = decodeFunction(for: properties, typeName: type.trimmed.description)
    } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      let cases = enumCases(in: enumDecl)
      marshalImpl = encodeEnumFunction(for: cases)
      unmarshalImpl = decodeEnumFunction(for: cases, typeName: type.trimmed.description)
    } else {
      context.diagnose(.init(node: Syntax(declaration), message: OnlyStructsOrEnumsAllowed()))
      return []
    }

    let needsConformance = alreadyConformsToXPCMarshal(declaration: declaration) == false
    let conformanceClause = needsConformance ? ": XPCMarshal" : ""

    let members = [marshalImpl, unmarshalImpl].joined(separator: "\n\n")

    let extDecl: DeclSyntax = """
      extension \(type.trimmed)\(raw: conformanceClause) {
      \(raw: members)
      }
      """

    if let ext = extDecl.as(ExtensionDeclSyntax.self) {
      return [ext]
    }
    return []
  }

  private static func storedProperties(in declaration: StructDeclSyntax) -> [Property] {
    declaration.memberBlock.members.compactMap { member in
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return nil }
      if varDecl.modifiers.contains(where: { $0.name.text == "static" }) {
        return nil
      }
      guard let binding = varDecl.bindings.first,
        let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
        binding.accessorBlock == nil,
        let type = binding.typeAnnotation?.type
      else {
        return nil
      }
      return Property(name: pattern.identifier.trimmed.text, type: type)
    }
  }

  private static func enumCases(in declaration: EnumDeclSyntax) -> [EnumCase] {
    declaration.memberBlock.members.flatMap { member -> [EnumCase] in
      guard let enumCaseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
        return [] as [EnumCase]
      }
      return enumCaseDecl.elements.map { element in
        let associatedValues: [AssociatedValue]
        if let parameters = element.parameterClause?.parameters {
          associatedValues = parameters.enumerated().map { index, parameter in
            let firstName = parameter.firstName?.text
            let externalName = firstName == "_" ? nil : firstName
            let binding = parameter.secondName?.text ?? externalName ?? "value\(index)"
            return AssociatedValue(
              label: externalName,
              binding: binding,
              type: parameter.type
            )
          }
        } else {
          associatedValues = []
        }

        return EnumCase(name: element.name.text, associatedValues: associatedValues)
      }
    }
  }

  private static func decodeFunction(for properties: [Property], typeName: String) -> String {
    let bindings = properties.map { property in
      let key = property.name
      if property.isOptional {
        return """
          let \(key): \(property.type) = try {
            guard let rawPtr = xpc_dictionary_get_value(dict, "\(key)") else { return nil }
            if xpc_get_type(rawPtr) == XPC_TYPE_NULL { return nil }
            let raw = SwiftXPC.XPCObject(xpc_object: rawPtr)
            return try .unmarshal(from: raw)
          }()
          """
      } else {
        return """
          let \(key): \(property.type) = try {
            guard let rawPtr = xpc_dictionary_get_value(dict, "\(key)") else { throw SwiftXPC.XPCMarshalError.missingKey("\(key)") }
            let raw = SwiftXPC.XPCObject(xpc_object: rawPtr)
            return try .unmarshal(from: raw)
          }()
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      static func unmarshal(from object: XPCObject) throws -> Self {
        let type = xpc_get_type(object.xpc_object)
        guard type == XPC_TYPE_DICTIONARY else { throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: type)) }
        let dict = object.xpc_object
        \(bindings)
        return \(typeName)(\(arguments))
      }
      """
  }

  private static func encodeFunction(for properties: [Property]) -> String {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            xpc_dictionary_set_value(dict, \"\(property.name)\", try value.marshal().xpc_object)
          } else {
            xpc_dictionary_set_value(dict, \"\(property.name)\", xpc_null_create())
          }
          """
      } else {
        return """
          xpc_dictionary_set_value(dict, \"\(property.name)\", try self.\(property.name).marshal().xpc_object)
          """
      }
    }.joined(separator: "\n")

    return """
      func marshal() throws -> XPCObject {
        let dict = xpc_dictionary_create(nil, nil, 0)
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: dict)
      }
      """
  }

  private static func encodeEnumFunction(for cases: [EnumCase]) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case .\(enumCase.name):
            xpc_dictionary_set_value(dict, \"case\", xpc_string_create(\"\(enumCase.name)\"))
          """
      }

      let bindingList = enumCase.associatedValues.map { "let \($0.binding)" }.joined(
        separator: ", ")
      let keys = enumCase.associatedValues.enumerated().map { index, value in
        value.label ?? String(index)
      }
      let payloadEncoding: String

      if enumCase.associatedValues.count == 1, enumCase.associatedValues.first?.label == nil {
        let value = enumCase.associatedValues[0]
        payloadEncoding = """
            let payload = try \(value.binding).marshal().xpc_object
            xpc_dictionary_set_value(dict, \"payload\", payload)
          """
      } else {
        let payloadAssignments = zip(keys, enumCase.associatedValues).map { key, value in
          """
            xpc_dictionary_set_value(payload, \"\(key)\", try \(value.binding).marshal().xpc_object)
          """
        }.joined(separator: "\n")

        payloadEncoding = """
            let payload = xpc_dictionary_create(nil, nil, 0)
          \(payloadAssignments)
            xpc_dictionary_set_value(dict, \"payload\", payload)
          """
      }

      return """
        case .\(enumCase.name)(\(bindingList)):
          xpc_dictionary_set_value(dict, \"case\", xpc_string_create(\"\(enumCase.name)\"))
        \(payloadEncoding)
        """
    }.joined(separator: "\n")

    return """
      func marshal() throws -> XPCObject {
        let dict = xpc_dictionary_create(nil, nil, 0)
        switch self {
        \(caseBranches)
        }
        return SwiftXPC.XPCObject(xpc_object: dict)
      }
      """
  }

  private static func decodeEnumFunction(for cases: [EnumCase], typeName: String) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case \"\(enumCase.name)\":
            return .\(enumCase.name)
          """
      }

      if enumCase.associatedValues.count == 1, let value = enumCase.associatedValues.first,
        value.label == nil
      {
        return """
          case \"\(enumCase.name)\":
            guard let payloadPtr = xpc_dictionary_get_value(dict, \"payload\") else {
              throw SwiftXPC.XPCMarshalError.missingKey(\"payload\")
            }
            let payload = SwiftXPC.XPCObject(xpc_object: payloadPtr)
            let value = try \(value.type).unmarshal(from: payload)
            return .\(enumCase.name)(value)
          """
      }

      let keys = enumCase.associatedValues.enumerated().map { index, value in
        value.label ?? String(index)
      }
      let valuesDecoding = zip(keys, enumCase.associatedValues).map { key, value in
        let binding = value.binding
        return """
            guard let raw_\(binding) = xpc_dictionary_get_value(payloadDict, \"\(key)\") else {
              throw SwiftXPC.XPCMarshalError.missingKey(\"\(key)\")
            }
            let \(binding) = try \(value.type).unmarshal(from: SwiftXPC.XPCObject(xpc_object: raw_\(binding)))
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
          guard let payloadPtr = xpc_dictionary_get_value(dict, \"payload\") else {
            throw SwiftXPC.XPCMarshalError.missingKey(\"payload\")
          }
          let payloadDict = payloadPtr
          let payloadType = xpc_get_type(payloadPtr)
          guard payloadType == XPC_TYPE_DICTIONARY else {
            throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: payloadType))
          }
          \(valuesDecoding)
          return .\(enumCase.name)(\(argumentList))
        """
    }.joined(separator: "\n")

    return """
      static func unmarshal(from object: XPCObject) throws -> Self {
        let type = xpc_get_type(object.xpc_object)
        guard type == XPC_TYPE_DICTIONARY else {
          throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: type))
        }
        let dict = object.xpc_object
        guard let casePtr = xpc_dictionary_get_value(dict, \"case\") else {
          throw SwiftXPC.XPCMarshalError.missingKey(\"case\")
        }
        let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))

        switch caseName {
        \(caseBranches)
        default:
          throw SwiftXPC.XPCMarshalError.unknownEnumCase(caseName, enumName: \"\(typeName)\")
        }
      }
      """
  }
}

private struct Property {
  let name: String
  let type: TypeSyntax

  var isOptional: Bool {
    let trimmed = type.trimmed.description
    if trimmed.hasSuffix("?") { return true }
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifier.name.text == "Optional"
    }
    return false
  }

  var wrappedTypeText: String {
    if let optional = type.as(OptionalTypeSyntax.self) {
      return optional.wrappedType.trimmed.description
    }
    if let identifier = type.as(IdentifierTypeSyntax.self),
      let generic = identifier.genericArgumentClause?.arguments.first?.argument
    {
      return generic.trimmed.description
    }
    let trimmed = type.trimmed.description
    if trimmed.hasSuffix("?") {
      return String(trimmed.dropLast())
    }
    return trimmed
  }
}

private func alreadyConformsToXPCMarshal(declaration: some DeclGroupSyntax) -> Bool {
  guard let inheritance = declaration.inheritanceClause else { return false }
  return inheritance.inheritedTypes.contains { inherited in
    inherited.type.trimmed.description == "XPCMarshal"
  }
}

private struct OnlyStructsOrEnumsAllowed: DiagnosticMessage {
  var message: String { "@XPCMarshal only supports struct or enum declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "onlyStructOrEnum") }
  var severity: DiagnosticSeverity { .error }
}

private struct EnumCase {
  let name: String
  let associatedValues: [AssociatedValue]
}

private struct AssociatedValue {
  let label: String?
  let binding: String
  let type: TypeSyntax
}
