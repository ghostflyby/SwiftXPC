// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
@testable import SwiftXPC

@XPCMarshal
public struct PublicMacroStruct: XPCMarshal {
  public let id: Int
}

@XPCMarshal
struct InternalMacroStruct: XPCMarshal {
  let id: Int
}

#if swift(>=5.9)
  @XPCMarshal
  package struct PackageMacroStruct: XPCMarshal {
    let id: Int
  }
#endif

@XPCMarshal
private struct FilePrivateMacroStruct: XPCMarshal {
  let id: Int
}

@XPCMarshal
private struct PrivateMacroStruct: XPCMarshal {
  let id: Int
}
