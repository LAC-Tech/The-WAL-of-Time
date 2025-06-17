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
                    if (((self.used_slots >> slot) & 1) == 0) continue;
                    if (eql(self.vals[slot], val)) return error.Duplicate;
                }
            }

            const free_slot = @ctz(~self.used_slots);
            if (free_slot >= max_slots) return error.Overflow;
            self.used_slots |= 1 << free_slot;
            self.vals[free_slot] = val;
            return @intCast(free_slot);
        }

        pub fn get(self: @This(), slot: Slot) ?T {
            if (((self.used_slots >> slot) & 1) == 0) {
                return null;
            }

            return self.vals[slot];
        }

        fn remove(self: *@This(), slot: Slot) ?T {
            if (((self.used_slots >> slot) & 1) == 0) {
                return null;
            }
            self.used_slots &= ~(1 << slot);
            const value = self.vals[slot];
            self.vals[slot] = undefined;
            return value;
        }
    };
}
