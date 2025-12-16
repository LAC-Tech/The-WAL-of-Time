# AGENTS.md - Development Guidelines

## Build Commands

Use zig build AND zig build test to confirm code changes.

- `zig build` - Build the project
- `zig build run` - Build and run the executable  
- `zig build test` - Run all tests
- `zig test src/main.zig` - Run single test file
- `zig test src/root.zig` - Run specific module tests

## Code Style Guidelines

### Imports
- Use explicit imports with aliases (e.g., `const std = @import("std")`)
- Group related std imports together at top of file
- Prefer specific imports over generic where appropriate

### Types & Naming
- Use PascalCase for types and public functions
- Use camelCase for variables and private functions  
- Use packed structs for binary protocols with explicit size assertions
- Use comptime assertions for struct sizes: `debug.assert(@sizeOf(Type) == expected)`

### Error Handling
- Use try/! for error propagation consistently
- Use defer for cleanup operations
- Handle IoUring completion errors properly, checking res < 0

### Testing
- Write comprehensive tests with meaningful names
- Use std.testing for assertions
- Include edge cases and serialization tests for data structures

### Memory Management
- Always pair alloc() with free() via defer
- Use arena allocators for temporary allocations when appropriate
