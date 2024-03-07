const std = @import("std");
const assert = std.debug.assert;

/// An intrusive first in/first out linked list.
/// The element type T must have a field called "next" of type ?*T
pub fn FIFO(comptime T: type) type {
    return struct {
        const Self = @This();

        in: ?*T = null,
        out: ?*T = null,
        count: u64 = 0,

        pub fn push(self: *Self, elem: *T) void {
            assert(elem.next == null);
            if (self.in) |in| {
                in.next = elem;
                self.in = elem;
            } else {
                assert(self.out == null);
                self.in = elem;
                self.out = elem;
            }
            self.count += 1;
        }

        pub fn pop(self: *Self) ?*T {
            const ret = self.out orelse return null;
            self.out = ret.next;
            ret.next = null;
            if (self.in == ret) self.in = null;
            self.count -= 1;
            return ret;
        }

        pub fn peek_last(self: Self) ?*T {
            return self.in;
        }

        pub fn peek(self: Self) ?*T {
            return self.out;
        }

        pub fn empty(self: Self) bool {
            return self.peek() == null;
        }

        /// Returns whether the linked list contains the given *exact element* (pointer comparison).
        pub fn contains(self: *const Self, elem_needle: *const T) bool {
            var iterator = self.peek();
            while (iterator) |elem| : (iterator = elem.next) {
                if (elem == elem_needle) return true;
            }
            return false;
        }

        /// Remove an element from the FIFO. Asserts that the element is
        /// in the FIFO. This operation is O(N), if this is done often you
        /// probably want a different data structure.
        pub fn remove(self: *Self, to_remove: *T) void {
            if (to_remove == self.out) {
                _ = self.pop();
                return;
            }
            var it = self.out;
            while (it) |elem| : (it = elem.next) {
                if (to_remove == elem.next) {
                    if (to_remove == self.in) self.in = elem;
                    elem.next = to_remove.next;
                    to_remove.next = null;
                    self.count -= 1;
                    self.plot();
                    break;
                }
            } else unreachable;
        }

        pub fn reset(self: *Self) void {
            self.* = .{};
        }
    };
}
