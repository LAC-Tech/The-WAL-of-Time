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
    comptime max_slots: usize,
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
            return .{
                .vals = try allocator.alloc(T, max_slots),
                .used_slots = 0,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            allocator.free(self.vals);
        }

        pub fn add(
            self: *@This(),
            val: T,
        ) Err!Slot {
            if (!opts.duplicates) {
                for (self.vals) |existing| {
                    if (eql(existing, val))
                        return error.Duplicate;
                }
            }

            const free_slot = @ctz(self.used_slots ^ math.maxInt(UInt));
            if (free_slot >= max_slots) return error.Overflow;
            self.used_slots |= @as(UInt, 1) << @intCast(free_slot);
            self.vals[free_slot] = val;
            return @intCast(free_slot);
        }

        pub fn get(self: @This(), slot: Slot) ?T {
            if (slot >= max_slots or (self.used_slots & (@as(UInt, 1) << slot)) == 0) {
                return null;
            }
            return self.vals[slot];
        }

        fn remove(self: *@This(), slot: Slot) T {
            debug.assert(slot < max_slots and (self.used_slots & (@as(UInt, 1) << slot)) != 0);
            self.used_slots &= ~(@as(UInt, 1) << slot);
            const removed = self.vals[slot];
            return removed;
        }
    };
}
