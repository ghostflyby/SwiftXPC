// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC

/// Errors produced on the client side while decoding a remote call reply.
@available(macOS 15, *)
@XPCMarshal
public enum XPCRemoteCallError: Error, Sendable, Equatable {
  case invalidReplyKind(expected: XPCReplyKind, actual: XPCReplyKind)
  case missingPayload(XPCReplyKind)
  case unsupportedThrownErrorType(String)
}


