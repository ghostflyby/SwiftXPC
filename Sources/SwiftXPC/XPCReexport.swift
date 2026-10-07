// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0

/// Re-exports Apple's `XPC` Swift module (the libxpc overlay), so that
/// `XPCDictionary`, `XPCArray`, `XPCSession`, `XPCListener`, and the raw
/// `xpc_*` surface are visible to every importer of SwiftXPC. The extensions
/// in `XPCContainerExtensions.swift` fill the API gaps that this package
/// relies on.
@_exported import XPC
