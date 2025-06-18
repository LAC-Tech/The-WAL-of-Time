//! Data structures

const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;

const Err = error{ Overflow, Duplicate };

pub fn SlotMap(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    comptime max_slots: u8,
    comptime opts: struct { duplicates: bool },
) type {
    const Slot = u8;

    comptime {
        debug.assert(math.maxInt(Slot) >= max_slots - 1);
    }

    const UInt = meta.Int(.unsigned, @intCast(max_slots));

    return struct {
        vals: []T,
        used_slots: UInt,

        pub fn init(allocator: mem.Allocator) !@This() {
            const vals = try allocator.alloc(T, @intCast(max_slots));
            @memset(vals, undefined);

            return .{
                .vals = vals,
                .used_slots = 0,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            allocator.free(self.vals);
        }

        pub fn add(self: *@This(), val: T) Err!Slot {
            if (!opts.duplicates) {
                var slot: Slot = 0;
                while (slot < max_slots) : (slot += 1) {
                    if (self.is_clear(slot)) continue;
                    if (eql(self.vals[slot], val)) return error.Duplicate;
                }
            }

            const free_slot = @ctz(~self.used_slots);
            if (free_slot >= max_slots) return error.Overflow;
            self.set(free_slot);
            self.vals[free_slot] = val;
            return @intCast(free_slot);
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
    const SM = SlotMap(u32, u32_eql, 8, .{ .duplicates = false });
    var sm = try SM.init(allocator);
    defer sm.deinit(allocator);

    const slot1 = try sm.add(42);
    try std.testing.expectEqual(0, slot1);
    try std.testing.expectEqual(42, sm.get(slot1).?);
    try std.testing.expectError(error.Duplicate, sm.add(42));

    const slot2 = try sm.add(99);
    try std.testing.expectEqual(1, slot2);
    try std.testing.expectEqual(99, sm.get(slot2).?);

    try std.testing.expectEqual(42, sm.remove(slot1).?);
    try std.testing.expectEqual(null, sm.get(slot1));

    try std.testing.expectEqual(99, sm.remove(slot2).?);
    try std.testing.expectEqual(null, sm.get(slot2));

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        _ = try sm.add(i);
    }
    try std.testing.expectError(error.Overflow, sm.add(100));
}
