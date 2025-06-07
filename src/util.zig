//! Data structures

const std = @import("std");
const mem = std.mem;

const Err = error{ Overflow, Duplicate };

pub fn SlotMap(
    comptime max_slots: usize,
    comptime T: type,
    comptime eql: fn (T, T) bool,
) type {
    const Slot = u8;

    comptime {
        std.debug.assert(@bitSizeOf(Slot) >= max_slots);
    }

    return struct {
        vals: []T,
        used_slots: [max_slots]u1,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .vals = try allocator.alloc(T, max_slots),
                .used_slots = [_]u1{0} ** max_slots,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            allocator.free(self.vals);
        }

        pub fn add(
            self: *@This(),
            val: T,
        ) Err!Slot {
            for (self.vals) |existing| {
                if (eql(existing, val))
                    return error.Duplicate;
            }

            // Find first free slot
            for (self.used_slots, 0..max_slots) |slot, idx| {
                if (slot == 0) { // Free slot found
                    self.used_slots[idx] = 1;
                    self.vals[idx] = val;
                    return @intCast(idx);
                }
            }

            return error.Overflow; // No free slots
        }

        pub fn get(self: @This(), slot: Slot) ?T {
            if (self.used_slots[slot] == 1) {
                return self.vals[slot];
            } else {
                return null;
            }
        }

        fn remove(self: *@This(), slot: Slot) T {
            self.used_slots[slot] = 0;
            const removed = self.names[slot];
            self.names[slot] = "";
            return removed;
        }
    };
}
