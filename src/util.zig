//! Data structures

const std = @import("std");
const mem = std.mem;
const debug = std.debug;

pub fn SortedVec(
    comptime T: type,
    comptime capacity: usize,
    comptime lessThan: fn (lhs: T, rhs: T) bool,
) type {
    return struct {
        list: std.BoundedArray(T, capacity),

        pub fn init() !@This() {
            return .{ .list = try std.BoundedArray(T, capacity).init(0) };
        }

        pub fn insert(self: *@This(), value: T) !void {
            try self.list.append(value);
            std.sort.insertion(T, self.list.slice(), {}, lessThan);
        }

        pub fn popIf(self: *@This(), pred: fn (T) bool) ?T {
            if (self.list.len == 0) return null;
            const last = self.list.get(self.list.len - 1);
            if (pred(last)) {
                return self.list.pop();
            }
            return null;
        }

        pub fn constSlice(self: *@This()) []const T {
            return self.list.constSlice();
        }
    };
}

const Err = error{ Overflow, Duplicate };

pub fn SlotMap(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    comptime max_slots: usize,
) type {
    const Slot = u8;

    comptime {
        debug.assert(@bitSizeOf(Slot) >= max_slots);
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
