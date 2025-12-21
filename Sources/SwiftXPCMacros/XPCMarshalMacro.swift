// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

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

    let access = accessLevelPrefix(for: declaration)
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      let properties = storedProperties(in: structDecl)
      if isFrozenStruct(structDecl) {
        marshalImpl = encodeFrozenStructFunction(for: properties, access: access)
        unmarshalImpl = decodeFrozenStructFunction(
          for: properties, typeName: type.trimmed.description, access: access)
      } else {
        marshalImpl = encodeFunction(for: properties, access: access)
        unmarshalImpl = decodeFunction(
          for: properties, typeName: type.trimmed.description, access: access)
      }
    } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
      guard isFinalClass(classDecl) else {
        context.diagnose(.init(node: Syntax(classDecl), message: OnlyFinalClassesAllowed()))
        return []
      }
      let properties = storedProperties(in: classDecl)
      marshalImpl = encodeFunction(for: properties, access: access)
      unmarshalImpl = decodeFunction(
        for: properties, typeName: type.trimmed.description, access: access)
    } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      if let rawType = rawEnumCandidateType(in: enumDecl) {
        guard isSupportedRawEnumType(rawType) else {
          context.diagnose(
            .init(
              node: Syntax(enumDecl), message: InvalidRawEnumType(type: rawType.trimmed.description)
            )
          )
          return []
        }
        marshalImpl = encodeRawEnumFunction(for: rawType, access: access)
        unmarshalImpl = decodeRawEnumFunction(
          for: rawType, typeName: type.trimmed.description, access: access)
      } else {
        let cases = enumCases(in: enumDecl)
        marshalImpl = encodeEnumFunction(for: cases, access: access)
        unmarshalImpl = decodeEnumFunction(
          for: cases, typeName: type.trimmed.description, access: access)
      }
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
}

private struct OnlyStructsOrEnumsAllowed: DiagnosticMessage {
  var message: String { "@XPCMarshal only supports struct, enum, or final class declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "onlyStructEnumFinalClass") }
  var severity: DiagnosticSeverity { .error }
}

private struct InvalidRawEnumType: DiagnosticMessage {
  let type: String
  var message: String {
    "@XPCMarshal raw enums only support String, Character, or integer/floating-point raw types (found \(type))"
  }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "invalidRawEnumType") }
  var severity: DiagnosticSeverity { .error }
}

private struct OnlyFinalClassesAllowed: DiagnosticMessage {
  var message: String { "@XPCMarshal only supports final class declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "onlyFinalClass") }
  var severity: DiagnosticSeverity { .error }
}
