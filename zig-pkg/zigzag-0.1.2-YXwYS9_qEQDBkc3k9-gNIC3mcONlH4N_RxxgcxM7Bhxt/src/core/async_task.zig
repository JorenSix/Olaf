//! Async task runner for background work in ZigZag.
//! Spawns threads that execute functions and queue result messages.

const std = @import("std");

/// Thread-safe result queue for async tasks.
pub fn AsyncRunner(comptime Msg: type) type {
    return struct {
        allocator: std.mem.Allocator,
        results: ResultQueue,
        next_id: u32 = 1,

        const Self = @This();
        const ResultQueue = std.array_list.Managed(?Msg);

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .results = ResultQueue.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.results.deinit();
        }

        /// Spawn a background task. The function runs on a new thread and
        /// its return value is queued as a message for the next frame.
        pub fn spawn(self: *Self, func: *const fn () ?Msg) u32 {
            const id = self.next_id;
            self.next_id += 1;

            const ctx = self.allocator.create(SpawnContext) catch return 0;
            ctx.* = .{ .func = func, .runner = self };

            _ = std.Thread.spawn(.{}, runTask, .{ctx}) catch {
                self.allocator.destroy(ctx);
                return 0;
            };

            return id;
        }

        /// Spawn with a context argument.
        pub fn spawnWithArg(self: *Self, comptime ArgT: type, arg: ArgT, func: *const fn (ArgT) ?Msg) u32 {
            const id = self.next_id;
            self.next_id += 1;

            const Closure = struct {
                arg_val: ArgT,
                func_ptr: *const fn (ArgT) ?Msg,
                runner_ptr: *Self,

                fn execute(closure: *@This()) void {
                    const result = closure.func_ptr(closure.arg_val);
                    if (result) |m| {
                        closure.runner_ptr.pushResult(m);
                    }
                }
            };

            const closure = self.allocator.create(Closure) catch return 0;
            closure.* = .{ .arg_val = arg, .func_ptr = func, .runner_ptr = self };

            _ = std.Thread.spawn(.{}, struct {
                fn run(c: *Closure) void {
                    c.execute();
                }
            }.run, .{closure}) catch {
                self.allocator.destroy(closure);
                return 0;
            };

            return id;
        }

        /// Poll for completed results. Returns messages from finished tasks.
        /// Call this each frame to collect async results.
        pub fn poll(self: *Self) []Msg {
            if (self.results.items.len == 0) return &.{};

            var msgs = std.array_list.Managed(Msg).init(self.allocator);
            for (self.results.items) |maybe_msg| {
                if (maybe_msg) |m| {
                    msgs.append(m) catch {};
                }
            }
            self.results.clearRetainingCapacity();
            return msgs.items;
        }

        fn pushResult(self: *Self, m: Msg) void {
            self.results.append(m) catch {};
        }

        const SpawnContext = struct {
            func: *const fn () ?Msg,
            runner: *Self,
        };

        fn runTask(ctx: *SpawnContext) void {
            const result = ctx.func();
            if (result) |m| {
                ctx.runner.pushResult(m);
            }
        }
    };
}
