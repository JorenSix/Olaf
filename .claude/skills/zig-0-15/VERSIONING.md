# Zig Skill Versioning Strategy

## Current Scope

This skill (`zig-0.15`) is pinned to **Zig 0.15.x** (specifically 0.15.2).

## Why Version-Pin?

1. **Stability**: solana-zig-bootstrap uses Zig 0.15.2
2. **Reproducibility**: Master branch changes daily
3. **Accuracy**: Version-specific APIs can be documented precisely
4. **Testability**: We can verify all examples compile

## Official Resources

| Resource | URL | Use Case |
|----------|-----|----------|
| 0.15.2 Language Ref | https://ziglang.org/documentation/0.15.2/ | Primary reference |
| 0.15.2 Std Library | https://ziglang.org/documentation/0.15.2/std/ | API details |
| 0.15.1 Release Notes | https://ziglang.org/download/0.15.1/release-notes.html | Breaking changes |
| Build System Guide | https://ziglang.org/learn/build-system/ | build.zig patterns |
| Source (Codeberg) | https://codeberg.org/ziglang/zig | Implementation reference |
| Master Docs | https://ziglang.org/documentation/master/ | Future API preview |

## Community Resources

| Resource | URL | Use Case |
|----------|-----|----------|
| Zig Cookbook | https://cookbook.ziglang.cc/ | Practical recipes (tracks 0.15.x) |
| Cookbook Source | https://github.com/zigcc/zig-cookbook | Recipe implementations |

The Zig Cookbook is especially valuable because:
- It tracks 0.15.x (same as this skill)
- Tested on Linux and macOS via CI
- Covers common tasks: file I/O, networking, cryptography, JSON, databases
- Real working code examples

## When to Update This Skill

Update this skill when:
1. solana-zig-bootstrap updates to a new Zig version
2. A new Zig stable release has significant breaking changes

## How to Handle New Zig Versions

### Option A: Update In-Place (Minor Changes)
If the new version (e.g., 0.15.3) has only bug fixes:
- Update version numbers in documentation
- Verify examples still compile
- Note any behavioral changes

### Option B: Create New Skill (Major Changes)
If there's a new major release (e.g., 0.16.0) with breaking changes:
1. Copy this skill to `skills/zig-0.16/`
2. Update all APIs and examples
3. Keep `zig-0.15` for projects still on 0.15.x
4. Update SKILL.md description to mention version

### Option C: Multi-Version Skill
For a skill that supports multiple versions:
```markdown
## ArrayList

### Zig 0.15+
```zig
try list.append(allocator, item);
```

### Zig 0.13-0.14
```zig
try list.append(item);
```
```

## Tracking Master Changes

To stay aware of upcoming breaking changes:

1. **Watch release notes**: https://ziglang.org/download/
2. **Check master docs**: Compare https://ziglang.org/documentation/master/std/ with 0.15.2
3. **Review Codeberg issues**: https://codeberg.org/ziglang/zig/issues
4. **Test periodically**: Build project with master Zig to catch issues early

## Current Project Constraint

This project (solana-program-sdk-zig) uses:
```bash
./solana-zig/zig version  # 0.15.2
```

The solana-zig toolchain is a modified Zig with SBF target support. It tracks stable Zig releases, not master.
