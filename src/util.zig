//! Data structures

const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;

const Slot = u8;
const AddRes = struct { slot: Slot, existed: bool };

pub fn SlotMap(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    comptime opts: struct { duplicates: bool },
) type {
    const UInt = u256;

    return struct {
        vals: []T,
        used_slots: UInt,
        max_slots: u8,

        pub fn init(allocator: mem.Allocator, max_slots: u8) !@This() {
            debug.assert(math.maxInt(Slot) >= max_slots - 1);
            const vals = try allocator.alloc(T, @intCast(max_slots));
            @memset(vals, undefined);

            return .{
                .vals = vals,
                .used_slots = 0,
                .max_slots = max_slots,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            allocator.free(self.vals);
        }

        /// If val already exists, returns Slot, else adds and returns a Slot
        pub fn add(self: *@This(), val: T) !AddRes {
            if (!opts.duplicates) {
                var slot: Slot = 0;
                while (slot < self.max_slots) : (slot += 1) {
                    if (self.is_clear(slot)) continue;
                    if (eql(self.vals[slot], val)) {
                        return .{ .slot = slot, .existed = true };
                    }
                }
            }

            const free_slot: Slot = @intCast(@ctz(~self.used_slots));
            if (free_slot >= self.max_slots) return error.Overflow;
            self.set(free_slot);
            self.vals[free_slot] = val;
            return .{ .slot = @intCast(free_slot), .existed = false };
        }

        pub fn get(self: @This(), slot: Slot) ?T {
            return if (self.is_set(slot)) self.vals[slot] else null;
        }

        fn remove(self: *@This(), slot: Slot) ?T {
            if (self.is_clear(slot)) return null;
            self.clear(slot);
            const value = self.vals[slot];
            self.vals[slot] = undefined;
            return value;
        }

        fn is_set(self: @This(), slot: Slot) bool {
            return ((self.used_slots >> @intCast(slot)) & 1) == 1;
        }

        fn is_clear(self: @This(), slot: Slot) bool {
            return ((self.used_slots >> @intCast(slot)) & 1) == 0;
        }

        fn clear(self: *@This(), slot: Slot) void {
            self.used_slots &= ~(@as(UInt, 1) << @intCast(slot));
        }

        fn set(self: *@This(), slot: Slot) void {
            self.used_slots |= @as(UInt, 1) << @intCast(slot);
        }
    };
}

fn u32_eql(a: u32, b: u32) bool {
    return std.meta.eql(a, b);
}

test "SlotMap" {
    const allocator = std.testing.allocator;
    const SM = SlotMap(u32, u32_eql, .{ .duplicates = false });
    var sm = try SM.init(allocator, 8);
    defer sm.deinit(allocator);

    const add_res1 = try sm.add(42);
    try std.testing.expectEqual(AddRes{ .slot = 0, .existed = false }, add_res1);
    try std.testing.expectEqual(42, sm.get(add_res1.slot).?);
    try std.testing.expectEqual(AddRes{ .slot = 0, .existed = true }, try sm.add(42));

    const add_res2 = try sm.add(99);
    try std.testing.expectEqual(AddRes{ .slot = 1, .existed = false }, add_res2);
    try std.testing.expectEqual(99, sm.get(add_res2.slot).?);

    try std.testing.expectEqual(42, sm.remove(add_res1.slot).?);
    try std.testing.expectEqual(null, sm.get(add_res1.slot));

    try std.testing.expectEqual(99, sm.remove(add_res2.slot).?);
    try std.testing.expectEqual(null, sm.get(add_res2.slot));

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        _ = try sm.add(i);
    }
    try std.testing.expectError(error.Overflow, sm.add(100));
}

pub fn RingBuf(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        write_idx: usize = 0,
        read_idx: usize = 0,

        pub const empty: @This() = .{};

        pub fn isFull(self: @This()) bool {
            return self.mask2(self.write_idx + self.items.len) == self.read_idx;
        }

        pub fn mask(self: @This(), index: usize) usize {
            return index % self.items.len;
        }

        pub fn mask2(self: @This(), index: usize) usize {
            return index % (2 * self.items.len);
        }

        pub fn push(self: *@This(), item: T) !void {
            if (self.isFull()) return error.Overflow;
            self.items[self.mask(self.write_idx)] = item;
            self.write_idx = self.mask2(self.write_idx + 1);
        }

        pub fn pop(self: *@This()) ?T {
            if (self.isEmpty()) return null;
            const item = self.items[self.mask(self.read_idx)];
            self.read_idx = self.mask2(self.read_idx + 1);
            return item;
        }

        pub fn isEmpty(self: @This()) bool {
            return self.write_idx == self.read_idx;
        }
    };
}

test "RingBuffer" {
    var rb: RingBuf(i32, 3) = .empty;
    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try std.testing.expectError(error.Overflow, rb.push(4));
    try std.testing.expectEqual(1, rb.pop().?);
    try std.testing.expectEqual(2, rb.pop().?);
    try std.testing.expectEqual(3, rb.pop().?);
    try std.testing.expectEqual(null, rb.pop());
}
