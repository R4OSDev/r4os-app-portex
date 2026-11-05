//! Batch small transport fragments without changing the durable prefix.
const std = @import("std");
pub const Buffer = struct {
    memory: []u8,
    pending: usize = 0,
    committed: u64,

    pub fn write(self: *Buffer, output: anytype, offset: u64, bytes: []const u8) !void {
        if (self.memory.len == 0 or offset != self.committed + self.pending) return error.PartialOffset;
        var remaining = bytes;
        while (remaining.len != 0) {
            const n = @min(self.memory.len - self.pending, remaining.len);
            @memcpy(self.memory[self.pending..][0..n], remaining[0..n]);
            self.pending += n;
            remaining = remaining[n..];
            if (self.pending == self.memory.len) try self.finish(output);
        }
    }
    pub fn finish(self: *Buffer, output: anytype) !void {
        if (self.pending == 0) return;
        try output.appendBatch(self.committed, self.memory[0..self.pending]);
        self.committed += self.pending;
        self.pending = 0;
    }
    pub fn reset(self: *Buffer) void {
        self.committed = 0;
        self.pending = 0;
    }
};

test "small download fragments retain exact bounded checkpoints and failed flushes" {
    const Output = struct {
        bytes: std.ArrayList(u8) = .empty,
        writes: usize = 0,
        fail: bool = false,
        pub fn appendBatch(self: *@This(), offset: u64, bytes: []const u8) !void {
            if (offset != self.bytes.items.len) return error.Offset;
            if (self.fail) return error.Write;
            try self.bytes.appendSlice(std.testing.allocator, bytes);
            self.writes += 1;
        }
    };
    var output: Output = .{};
    defer output.bytes.deinit(std.testing.allocator);
    const memory = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(memory);
    var writer = Buffer{ .memory = memory, .committed = 0 };
    const source = try std.testing.allocator.alloc(u8, 1024 * 1024 + 31);
    defer std.testing.allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @truncate(i);
    var offset: usize = 0;
    while (offset < source.len) {
        const n = @min(511, source.len - offset);
        try writer.write(&output, offset, source[offset..][0..n]);
        offset += n;
    }
    try std.testing.expectEqual(@as(usize, 16), output.writes);
    try std.testing.expectError(error.PartialOffset, writer.write(&output, 0, "foreign"));
    output.fail = true;
    try std.testing.expectError(error.Write, writer.finish(&output));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), writer.committed);
    try std.testing.expectEqual(@as(usize, 31), writer.pending);
    output.fail = false;
    try writer.finish(&output);
    try std.testing.expectEqual(@as(usize, 17), output.writes);
    try std.testing.expectEqualSlices(u8, source, output.bytes.items);
}
