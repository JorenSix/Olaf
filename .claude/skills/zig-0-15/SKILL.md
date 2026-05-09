---
name: zig-0-15
description: This skill provides Zig 0.15.x API guidance and should be used when writing or reviewing Zig code. It ensures correct usage of Zig 0.15 APIs, preventing common mistakes from using outdated 0.11/0.12/0.13/0.14 patterns. Essential for ArrayList, std.Io.Writer/Reader (Writergate), HTTP client, Ed25519, JSON, and type introspection APIs.
license: MIT
compatibility:
  - opencode
  - claude-code
metadata:
  version: "0.15.2"
  language: "zig"
  category: "programming-language"
---

# Zig 0.15.x Programming Guide

> **Version Scope**: This skill is pinned to **Zig 0.15.x** (specifically 0.15.2).
> **Release Notes**: https://ziglang.org/download/0.15.1/release-notes.html

## Local Documentation First

Run `zig env` to discover installation paths — never hardcode them. Key fields: `.lib_dir`, `.std_dir`, `.version`.

- **Language Reference**: `<lib_dir>/../doc/langref.html`
- **Std Library Source**: read files under `.std_dir` for API verification.

Always check local docs before web search.

## Critical API Changes in Zig 0.15

### ArrayList (BREAKING)

All mutating methods now require explicit `allocator` parameter:

```zig
// ❌ WRONG (0.13 and earlier)
var list = std.ArrayList(T).init(allocator);
try list.append(item);
try list.appendSlice(items);
_ = try list.addOne();
_ = try list.toOwnedSlice();

// ✅ CORRECT (0.15+)
var list = try std.ArrayList(T).initCapacity(allocator, 16);
defer list.deinit(allocator);
try list.append(allocator, item);
try list.appendSlice(allocator, items);
_ = try list.addOne(allocator);
_ = try list.toOwnedSlice(allocator);

// AssumeCapacity variants do NOT need allocator
list.appendAssumeCapacity(item);
```

| Method | 0.13 | 0.15+ |
|--------|------|-------|
| `append` | `try list.append(item)` | `try list.append(allocator, item)` |
| `appendSlice` | `try list.appendSlice(items)` | `try list.appendSlice(allocator, items)` |
| `addOne` | `try list.addOne()` | `try list.addOne(allocator)` |
| `ensureTotalCapacity` | `try list.ensureTotalCapacity(n)` | `try list.ensureTotalCapacity(allocator, n)` |
| `toOwnedSlice` | `try list.toOwnedSlice()` | `try list.toOwnedSlice(allocator)` |
| `deinit` | `list.deinit()` | `list.deinit(allocator)` |

### HashMap

**Managed** (stores allocator internally):
```zig
var map = std.StringHashMap(V).init(allocator);
defer map.deinit();
try map.put(key, value);  // No allocator needed
```

**Unmanaged** (requires allocator for each operation):
```zig
var map = std.StringHashMapUnmanaged(V){};
defer map.deinit(allocator);
try map.put(allocator, key, value);  // Allocator required
```

## Writergate: New std.Io.Writer and std.Io.Reader (MAJOR REWRITE)

Zig 0.15 replaces the old generic `std.io` reader/writer with concrete, vtable-based `std.Io.Reader` / `std.Io.Writer`. Key differences from the old API:

- **Concrete types** (not `anytype`) — can be stored in structs, passed as parameters
- **Caller provides buffer** — no hidden allocations
- **Precise errors** — `error{ReadFailed}` / `error{WriteFailed}` instead of `anyerror`
- **Ring-buffer design** — efficient peek/take without copies

### std.Io.Writer

```zig
// Core struct (caller provides buffer, vtable handles draining)
pub const Writer = struct {
    vtable: *const VTable,
    buffer: []u8,       // caller-provided; buffer[0..end] = buffered data
    end: usize = 0,
};
```

**Key methods:**

| Method | Purpose |
|--------|---------|
| `writeAll(bytes)` | Write all bytes (may buffer + drain) |
| `writeByte(byte)` | Write single byte |
| `print(fmt, args)` | Formatted write |
| `flush()` | Drain all buffered data |
| `buffered()` | Get slice of currently buffered data |

**Creating writers:**

```zig
// 1. Fixed buffer (in-memory, bounded)
var buf: [256]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try writer.print("count: {d}", .{42});
// written data: buf[0..writer.end]

// 2. Allocating (dynamic, growable)
var aw: std.Io.Writer.Allocating = .init(allocator);
defer aw.deinit();
try aw.writer.print("hello {s}", .{"world"});
const output = aw.written();           // []u8 view
const owned = try aw.toOwnedSlice();   // caller owns

// 3. From file
var file_buf: [4096]u8 = undefined;
var file_writer = file.writer(&file_buf);
try file_writer.interface.writeAll("data\n");
try file_writer.interface.flush();

// 4. stdout / stderr
var stdout_buf: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
const stdout: *std.Io.Writer = &stdout_writer.interface;
try stdout.print("Hello\n", .{});
try stdout.flush();  // Don't forget!
```

### std.Io.Reader

```zig
// Core struct (caller provides buffer, vtable handles filling)
pub const Reader = struct {
    vtable: *const VTable,
    buffer: []u8,       // caller-provided; buffer[seek..end] = buffered data
    seek: usize,        // bytes consumed
    end: usize,         // bytes available
};
```

**Key methods:**

| Method | Purpose |
|--------|---------|
| `take(n)` | Read exactly n bytes, advance position |
| `takeByte()` | Read one byte |
| `takeInt(T, endian)` | Read integer with endianness |
| `takeDelimiterExclusive(delim)` | Read until delimiter (excluded) |
| `takeDelimiterInclusive(delim)` | Read until delimiter (included) |
| `peek(n)` | Look at next n bytes without consuming |
| `peekByte()` | Peek one byte |
| `readSliceAll(buf)` | Fill entire buffer from stream |
| `allocRemaining(gpa, limit)` | Read all remaining into allocated slice |
| `stream(writer, limit)` | Pump data to a Writer |
| `streamRemaining(writer)` | Stream all data until EOF |
| `discard(limit)` | Skip bytes without reading |
| `buffered()` | Get slice of currently buffered data |

**Creating readers:**

```zig
// 1. Fixed buffer (in-memory, read-only)
var reader: std.Io.Reader = .fixed("line1\nline2\n");

// 2. From file
var read_buf: [4096]u8 = undefined;
var file_reader = file.reader(&read_buf);
const data = try file_reader.interface.take(10);

// 3. Limited (wrap existing reader with byte limit)
var limit_buf: [256]u8 = undefined;
var limited = reader.limited(.limited(100), &limit_buf);
// limited.interface reads at most 100 bytes
```

**Line-by-line reading:**

```zig
while (reader.takeDelimiterExclusive('\n')) |line| {
    // process line (delimiter not included)
} else |err| switch (err) {
    error.EndOfStream => {},
    else => return err,
}
```

**Read entire content into allocated slice:**

```zig
const contents = try reader.allocRemaining(allocator, .limited(1 << 20));
defer allocator.free(contents);
```

### std.Io.Limit

Controls how many bytes a stream/read operation consumes:

```zig
const limit = std.Io.Limit.limited(1024);  // at most 1024 bytes
const unlimited = std.Io.Limit.unlimited;   // no limit
const nothing = std.Io.Limit.nothing;       // zero bytes
```

### Reader ↔ Writer: Streaming

```zig
// Pump all data from reader to writer
_ = try reader.streamRemaining(&writer);

// Pump with byte limit
_ = try reader.stream(&writer, .limited(4096));
```

### File.Reader / File.Writer

`std.fs.File` returns wrapper structs; use the `.interface` field to get the `std.Io.Reader` / `std.Io.Writer`:

```zig
var write_buf: [4096]u8 = undefined;
var file_writer = file.writer(&write_buf);
try file_writer.interface.writeAll("hello\n");  // .interface is *std.Io.Writer
try file_writer.interface.flush();

var read_buf: [4096]u8 = undefined;
var file_reader = file.reader(&read_buf);
const line = try file_reader.interface.takeDelimiterExclusive('\n');
```

Two modes: `file.writer(buf)` (positional, threadsafe) vs `file.writerStreaming(buf)` (sequential). Prefer positional when available.

### Migration from Old std.io

| Old (0.14) | New (0.15) |
|------------|------------|
| `std.io.getStdOut().writer()` | `std.fs.File.stdout().writer(&buf)` → `.interface` |
| `std.io.fixedBufferStream(&buf)` | `std.Io.Writer.fixed(&buf)` / `std.Io.Reader.fixed(data)` |
| `fbs.getWritten()` | `writer.buffered()` |
| `writer.writeAll(data)` | same, but on `*std.Io.Writer` |
| `GenericWriter` / `AnyWriter` | `*std.Io.Writer` (concrete) |
| `GenericReader` / `AnyReader` | `*std.Io.Reader` (concrete) |
| `reader.readAll(buf)` | `reader.readSliceAll(buf)` |
| `reader.readUntilDelimiter(delim, buf)` | `reader.takeDelimiterExclusive(delim)` |

**Bridge adapter** — if you still have old-style `GenericWriter` and need new interface:

```zig
fn useOldWriter(old_writer: anytype) !void {
    var adapter = old_writer.adaptToNewApi(&.{});
    const w: *std.Io.Writer = &adapter.new_interface;
    try w.print("{s}", .{"example"});
}
```

### HTTP Client (MAJOR REWRITE)

```zig
// High-level fetch()
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();
const result = try client.fetch(.{
    .location = .{ .url = "https://example.com/api" },
    .method = .GET,
});

// Low-level request/response
const uri = try std.Uri.parse("https://example.com/api");
var req = try client.request(.POST, uri, .{
    .extra_headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    },
});
defer req.deinit();
try req.sendBodyComplete(@constCast("{\"key\": \"value\"}"));

var redirect_buf: [4096]u8 = undefined;
var response = try req.receiveHead(&redirect_buf);
// Read body via std.Io.Reader
var body_reader = response.reader(&redirect_buf);
const body = try body_reader.allocRemaining(allocator, .limited(1 << 20));
defer allocator.free(body);
```

### Base64

```zig
// ❌ WRONG (0.13) — std.base64.standard.encode / .decode
// ✅ CORRECT (0.15+) — use .Encoder / .Decoder sub-namespace

// Encode
const encoded = std.base64.standard.Encoder.encode(&buf, data);

// Decode
const decoded = try std.base64.standard.Decoder.decode(&out_buf, encoded);

// URL-safe variant: std.base64.url_safe.Encoder / .Decoder
```

### Ed25519 Cryptography (MAJOR CHANGES)

Key types are now structs, not raw byte arrays:

```zig
const Ed25519 = std.crypto.sign.Ed25519;

// ❌ WRONG (0.13 - SecretKey was [32]u8)
const secret: [32]u8 = ...;
const kp = Ed25519.KeyPair.fromSecretKey(secret);

// ✅ CORRECT (0.15+ - SecretKey is struct with 64 bytes)
// From 32-byte seed (deterministic):
const seed: [32]u8 = ...;
const kp = try Ed25519.KeyPair.generateDeterministic(seed);

// From 64-byte secret key:
var secret_bytes: [64]u8 = ...;
const secret_key = try Ed25519.SecretKey.fromBytes(secret_bytes);
const kp = try Ed25519.KeyPair.fromSecretKey(secret_key);

// Get public key bytes:
const pubkey_bytes: [32]u8 = kp.public_key.toBytes();

// Get seed:
const seed: [32]u8 = kp.secret_key.seed();
```

Signature changes:
```zig
// ❌ WRONG (0.13 - fromBytes returned error union)
const sig = try Ed25519.Signature.fromBytes(bytes);

// ✅ CORRECT (0.15+ - fromBytes does NOT return error)
const sig = Ed25519.Signature.fromBytes(bytes);
```

### Type Introspection Enums (Case Change)

```zig
// ❌ WRONG (0.13 - PascalCase)
if (@typeInfo(T) == .Slice) { ... }
if (@typeInfo(T) == .Pointer) { ... }
if (@typeInfo(T) == .Struct) { ... }

// ✅ CORRECT (0.15+ - lowercase/escaped)
if (@typeInfo(T) == .slice) { ... }
if (@typeInfo(T) == .pointer) { ... }
if (@typeInfo(T) == .@"struct") { ... }
if (@typeInfo(T) == .@"enum") { ... }
if (@typeInfo(T) == .@"union") { ... }
if (@typeInfo(T) == .array) { ... }
if (@typeInfo(T) == .optional) { ... }
```

### Custom Format Functions

```zig
// ❌ WRONG (0.13 - used {} format specifier)
pub fn format(
    self: Self,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try writer.writeAll("...");
}
// Usage: std.fmt.bufPrint(&buf, "{}", .{value});

// ✅ CORRECT (0.15+ - use {f} format specifier)
pub fn format(self: Self, writer: anytype) !void {
    _ = self;
    try writer.writeAll("...");
}
// Usage: std.fmt.bufPrint(&buf, "{f}", .{value});
```

### JSON Parsing and Serialization

```zig
const MyStruct = struct {
    name: []const u8,
    value: u32,
};

// ✅ CORRECT: Parsing (0.15+)
const json_str =
    \\{"name": "test", "value": 42}
;
const parsed = try std.json.parseFromSlice(MyStruct, allocator, json_str, .{});
defer parsed.deinit();
const data = parsed.value;

// ✅ CORRECT: Serialization (0.15.2 - writer-based API)
// Note: There is NO stringifyAlloc in 0.15.2!

// Method 1: Using std.json.Stringify with Allocating writer
var out: std.Io.Writer.Allocating = .init(allocator);
defer out.deinit();
var stringify: std.json.Stringify = .{
    .writer = &out.writer,
    .options = .{},
};
try stringify.write(data);
const json_output = out.written();

// Method 2: Using std.fmt with json.fmt wrapper
const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{})});
defer allocator.free(formatted);

// Method 3: To fixed buffer
var buf: [1024]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
var writer = fbs.writer();
var stringify2: std.json.Stringify = .{
    .writer = &writer.adaptToNewApi(&.{}).new_interface,
    .options = .{},
};
try stringify2.write(data);
const output = fbs.getWritten();

// Parse options
const parsed2 = try std.json.parseFromSlice(MyStruct, allocator, json_str, .{
    .allocate = .alloc_always,
    .ignore_unknown_fields = true,
    .max_value_len = 1 << 20,
});
```

## Common Error Messages and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `expected 2 argument(s), found 1` | ArrayList method missing allocator | Add allocator as first argument |
| `no field or member function named 'encode'` | Using `std.base64.standard.encode` | Use `std.base64.standard.Encoder.encode` |
| `no field or member function named 'open'` | Using old HTTP API | Use `client.request()` or `client.fetch()` |
| `expected type 'SecretKey', found '[32]u8'` | Ed25519 SecretKey is now struct | Use `generateDeterministic(seed)` |
| `expected error union type, found 'Signature'` | Signature.fromBytes doesn't return error | Remove `try` |
| `enum has no member named 'Slice'` | @typeInfo enum case changed | Use lowercase `.slice` |
| `no field named 'root_source_file'` | Old build.zig API | Use `root_module = b.createModule(...)` |

## Build System (build.zig) Changes (MAJOR REWRITE)

**Official Guide**: https://ziglang.org/learn/build-system/

### Executable Creation

```zig
// ❌ WRONG (0.14 and earlier)
const exe = b.addExecutable(.{
    .name = "hello",
    .root_source_file = .{ .path = "src/main.zig" },
    .target = target,
    .optimize = optimize,
});

// ✅ CORRECT (0.15+)
const exe = b.addExecutable(.{
    .name = "hello",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Library Creation

```zig
// ❌ WRONG (0.14 - addSharedLibrary/addStaticLibrary)
const lib = b.addSharedLibrary(.{
    .name = "mylib",
    .root_source_file = .{ .path = "src/lib.zig" },
});

// ✅ CORRECT (0.15+ - unified addLibrary with linkage)
const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .dynamic,  // or .static
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Path Handling

```zig
// ❌ WRONG (0.14 - .path field)
.root_source_file = .{ .path = "src/main.zig" },

// ✅ CORRECT (0.15+ - use b.path())
.root_source_file = b.path("src/main.zig"),
```

### Module Dependencies

```zig
// ❌ WRONG (0.14)
exe.addModule("sdk", sdk_module);

// ✅ CORRECT (0.15+)
exe.root_module.addImport("sdk", sdk_module);
```

### Testing

```zig
// ✅ CORRECT (0.15+)
const unit_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,  // use b.graph.host for native target
    }),
});

const run_unit_tests = b.addRunArtifact(unit_tests);
const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_unit_tests.step);
```

### Complete build.zig Example

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
```

## Language Changes

### usingnamespace Removed

The `usingnamespace` keyword has been completely removed in Zig 0.15.

```zig
// ❌ WRONG (removed in 0.15)
pub usingnamespace @import("other.zig");

// ✅ CORRECT - explicit re-exports
pub const foo = @import("other.zig").foo;
pub const bar = @import("other.zig").bar;

// ✅ CORRECT - namespace via field
pub const other = @import("other.zig");
// Usage: other.foo, other.bar
```

**Migration for mixins**: Use zero-bit fields with `@fieldParentPtr`:

```zig
// ❌ OLD mixin pattern
pub const Foo = struct {
    count: u32 = 0,
    pub usingnamespace CounterMixin(Foo);
};

// ✅ NEW mixin pattern (0.15+)
pub fn CounterMixin(comptime T: type) type {
    return struct {
        pub fn increment(m: *@This()) void {
            const x: *T = @alignCast(@fieldParentPtr("counter", m));
            x.count += 1;
        }
    };
}

pub const Foo = struct {
    count: u32 = 0,
    counter: CounterMixin(Foo) = .{},  // zero-bit field
};
// Usage: foo.counter.increment()
```

### async/await Keywords Removed

The `async`, `await`, and `@frameSize` have been removed. Async functionality will be provided via the standard library's new I/O interface.

```zig
// ❌ REMOVED - no async/await keywords
async fn fetchData() ![]u8 { ... }
const result = await fetchData();

// ✅ Use std.Io interfaces or threads instead
```

### Arithmetic on undefined

Operations on `undefined` that could trigger illegal behavior now cause compile errors:

```zig
const a: u32 = 0;
const b: u32 = undefined;

// ❌ COMPILE ERROR in 0.15+
_ = a + b;  // error: use of undefined value here causes illegal behavior
```

### Lossy Integer to Float Coercion

Compile error if integer cannot be precisely represented:

```zig
// ❌ COMPILE ERROR in 0.15+
const val: f32 = 123_456_789;  // error: cannot represent precisely

// ✅ CORRECT - opt-in to floating-point rounding
const val: f32 = 123_456_789.0;
```

