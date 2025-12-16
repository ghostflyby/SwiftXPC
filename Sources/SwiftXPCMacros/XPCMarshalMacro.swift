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
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      context.diagnose(.init(node: Syntax(declaration), message: OnlyStructsAllowed()))
      return []
    }

    let properties = storedProperties(in: structDecl)
    let marshalImpl = encodeFunction(for: properties)
    let unmarshalImpl = decodeFunction(for: properties, typeName: type.trimmed.description)

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

  private static func decodeFunction(for properties: [Property], typeName: String) -> String {
    let bindings = properties.map { property in
      let key = property.name
      if property.isOptional {
        let wrapped = property.wrappedTypeText
        return """
          let \(key): \(property.type) = try {
            guard let rawPtr = xpc_dictionary_get_value(dict, "\(key)") else { return nil }
            if xpc_get_type(rawPtr) == XPC_TYPE_NULL { return nil }
            let raw = SwiftXPC.XPCObjectUnknown(xpc_object: rawPtr)
            return try \(wrapped).unmarshal(from: raw)
          }()
          """
      } else {
        return """
          let \(key): \(property.type) = try {
            guard let rawPtr = xpc_dictionary_get_value(dict, "\(key)") else { throw SwiftXPC.XPCMarshalError.missingKey("\(key)") }
            let raw = SwiftXPC.XPCObjectUnknown(xpc_object: rawPtr)
            return try \(property.type).unmarshal(from: raw)
          }()
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      static func unmarshal(from object: any XPCObject) throws -> Self {
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
      func marshal() throws -> any XPCObject {
        let dict = xpc_dictionary_create(nil, nil, 0)
      \(assignments)
        return SwiftXPC.XPCObjectUnknown(xpc_object: dict)
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

private struct OnlyStructsAllowed: DiagnosticMessage {
  var message: String { "@XPCCodable only supports struct declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "onlyStruct") }
  var severity: DiagnosticSeverity { .error }
}
