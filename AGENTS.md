## Repository Guidelines

### Project Structure & Module Organization
Source code lives under `Sources/` with primary modules like `SwiftXPC`, `SwiftXPCMacros`, and `DistributedXPC`. Tests live in `Tests/SwiftXPCTests/`. Package metadata is in `Package.swift`, and shared configuration (if any) belongs in `.swiftpm/` or project root files. Use `Sources/SwiftXPC` for runtime API changes and `Sources/SwiftXPCMacros` for macro expansion logic.

### Build, Test, and Development Commands
- `swift build`: Compile the package.
- `swift test`: Run the test suite (uses Swift Testing).
- `swift test --filter <TestName>`: Run a specific test (e.g., `swift test --filter EnumLayoutWithPayload`).

### Coding Style & Naming Conventions
- Swift formatting follows standard Swift style (2-space indent inside multi-line closures where applicable; 2-space alignment in this repo’s sources).
- Public APIs use UpperCamelCase types and lowerCamelCase members.
- Tests use descriptive UpperCamelCase function names (e.g., `EnumLayoutWithPayload`).
- Avoid unnecessary non-ASCII identifiers; keep comments brief and purposeful.
- Run the `swift format` tool with proper arguments if needed.

### Testing Guidelines
Tests use `Testing` and live under `Tests/SwiftXPCTests`. Keep tests focused and grouped by domain (e.g., `EnumLayoutTests.swift`, `StructRoundTripTests.swift`). Layout tests should assert XPC object types and payload shapes directly using `xpc_*` functions. Run all tests with `swift test` before committing.

### Commit & Pull Request Guidelines
Commit messages are short, imperative, and scoped to a change (e.g., “Adjust unlabeled enum layout”). Keep commits focused; avoid mixing refactors with behavior changes. For PRs, include a clear summary, test results, and any relevant behavior changes (especially serialization layout changes).

Use convention commits.

### Agent Notes
