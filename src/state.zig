//! Portex-owned binding metadata only, never MODULES.JSON or system payloads.
//! Call save under the shared installation owner's serialization, after its
//! real successful receipt. Merely viewing the store never creates a binding.
const std = @import("std");
const r4os = @import("r4os");
const model = @import("model.zig");
pub const max_bytes = 1024 * 1024;
pub const default_path = "C:\\R4OS\\DATA\\PORTEX\\BINDINGS.JSON";

comptime {
    // Also typecheck the real SDK writer/atomic adapter when host fixtures use
    // a different Files implementation. No operation runs during this check.
    std.testing.refAllDecls(struct {
        pub fn nativeSave(files: *const r4os.Files, allocator: std.mem.Allocator) !void {
            try save(files, allocator, default_path, .{});
        }
    });
}

pub fn load(files: anytype, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(model.Bindings) {
    const bytes = try readBytes(files, allocator, path, max_bytes);
    defer if (bytes) |b| allocator.free(b);
    return model.Bindings.parse(allocator, bytes orelse "{\"schema_version\":1,\"bindings\":[]}");
}

pub fn readBytes(files: anytype, allocator: std.mem.Allocator, path: []const u8, limit: usize) !?[]u8 {
    const parsed_path = try r4os.AbsoluteFilePath.parse(path);
    const info = switch (files.metadata(parsed_path.asZ())) {
        .found => |v| v,
        .missing => return null,
        .failure => return error.BindingRead,
    };
    const size = r4os.metadata2.fileSize(&info) orelse return error.BindingSize;
    if (info.flags & r4os.abi.file_metadata2_flag_directory != 0 or size == 0 or size > limit) return error.BindingSize;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    const count = switch (files.read(parsed_path.asZ(), bytes)) {
        .bytes => |n| n,
        else => return error.BindingRead,
    };
    if (count != bytes.len) return error.BindingRead;
    return bytes;
}

pub fn save(files: anytype, allocator: std.mem.Allocator, path: []const u8, value: model.Bindings) !void {
    const bytes = try value.encode(allocator);
    defer allocator.free(bytes);
    try writeBytes(files, allocator, path, bytes, max_bytes);
}

pub fn writeBytes(files: anytype, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, limit: usize) !void {
    if (bytes.len == 0 or bytes.len > limit) return error.BindingSize;
    const target = try r4os.AbsoluteFilePath.parse(path);
    // The native atomic owner requires short stage/backup names on every
    // volume. Replace the extension rather than appending a second one.
    const base = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return error.BindingPath;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const stem = path[0..if (dot > base) dot else path.len];
    const staged_name = try std.fmt.allocPrint(allocator, "{s}.NEW", .{stem});
    defer allocator.free(staged_name);
    const backup_name = try std.fmt.allocPrint(allocator, "{s}.BAK", .{stem});
    defer allocator.free(backup_name);
    const intent_name = try std.fmt.allocPrint(allocator, "{s}.TXN", .{stem});
    defer allocator.free(intent_name);
    const staged = try r4os.AbsoluteFilePath.parse(staged_name);
    const backup = try r4os.AbsoluteFilePath.parse(backup_name);
    const intent_path = try r4os.AbsoluteFilePath.parse(intent_name);
    const current = try readBytes(files, allocator, path, limit);
    defer if (current) |value| allocator.free(value);
    const saved = try readBytes(files, allocator, intent_name, 512);
    defer if (saved) |value| allocator.free(value);
    const desired_hash = hash(bytes);
    const old_hash: ?[64]u8 = if (current) |value| hash(value) else null;
    if (saved) |value| {
        const parsed = try std.json.parseFromSlice(CommitIntent, allocator, value, .{});
        defer parsed.deinit();
        const intent = parsed.value;
        if (intent.schema != 1 or intent.next.len != 64 or (intent.previous != null and intent.previous.?.len != 64)) return error.BindingIntent;
        if (sameHash(old_hash, intent.next)) {
            // The replacement succeeded before a crash. Only the old bytes
            // attested BEFORE that replacement may now be removed.
            try cleanupBackup(files, allocator, backup_name, intent.previous, limit);
            if ((try readBytes(files, allocator, staged_name, limit))) |left| {
                defer allocator.free(left);
                if (!std.mem.eql(u8, &hash(left), intent.next)) return error.BindingStageConflict;
                if (files.delete(staged.asZ()) != .ok) return error.BindingCleanup;
            }
            if (files.delete(intent_path.asZ()) != .ok) return error.BindingCleanup;
            // Resume the completed intent first, then admit a new one.
            if (std.mem.eql(u8, &desired_hash, intent.next)) return;
            return writeBytes(files, allocator, path, bytes, limit);
        }
        if (!sameOptionalHash(old_hash, intent.previous) or !std.mem.eql(u8, &desired_hash, intent.next)) return error.BindingIntentConflict;
    } else {
        if (current) |value| if (std.mem.eql(u8, value, bytes)) return;
        if ((try readBytes(files, allocator, backup_name, limit))) |unknown| {
            allocator.free(unknown);
            return error.BindingBackupConflict;
        }
        const intent = try std.json.Stringify.valueAlloc(allocator, CommitIntent{ .previous = if (old_hash) |*h| h else null, .next = &desired_hash }, .{});
        defer allocator.free(intent);
        try writeNew(files, allocator, intent_name, intent, 512);
    }
    const leftover = try readBytes(files, allocator, staged_name, limit);
    if (leftover) |old| {
        defer allocator.free(old);
        // Recover an identical completed stage; never replace foreign bytes.
        if (!std.mem.eql(u8, old, bytes)) return error.BindingStageConflict;
    } else {
        var writer = switch (files.streamWriter(staged.asZ(), r4os.abi.file_stream_open_create)) {
            .writer => |v| v,
            .failure => return error.BindingStage,
        };
        var complete = false;
        defer if (!complete) {
            _ = writer.abort();
        };
        if (writer.write(bytes) != .ok or writer.finish() != .ok) return error.BindingStage;
        complete = true;
    }
    if (files.replaceAtomic(target.asZ(), staged.asZ(), backup.asZ(), .{}) != .ok) return error.BindingCommit;
    const observed = (try readBytes(files, allocator, path, limit)) orelse return error.BindingReadback;
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, bytes)) return error.BindingReadback;
    try cleanupBackup(files, allocator, backup_name, if (old_hash) |*h| h else null, limit);
    if (files.delete(intent_path.asZ()) != .ok) return error.BindingCleanup;
}

const CommitIntent = struct { schema: u32 = 1, previous: ?[]const u8, next: []const u8 };
fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn sameHash(observed: ?[64]u8, expected: []const u8) bool {
    return if (observed) |h| std.mem.eql(u8, &h, expected) else false;
}
fn sameOptionalHash(observed: ?[64]u8, expected: ?[]const u8) bool {
    return if (expected) |h| sameHash(observed, h) else observed == null;
}
fn cleanupBackup(files: anytype, allocator: std.mem.Allocator, path: []const u8, expected: ?[]const u8, limit: usize) !void {
    const bytes = (try readBytes(files, allocator, path, limit)) orelse return;
    defer allocator.free(bytes);
    if (expected == null or !std.mem.eql(u8, &hash(bytes), expected.?)) return error.BindingBackupConflict;
    const parsed = try r4os.AbsoluteFilePath.parse(path);
    if (files.delete(parsed.asZ()) != .ok) return error.BindingCleanup;
}
fn writeNew(files: anytype, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, limit: usize) !void {
    const parsed = try r4os.AbsoluteFilePath.parse(path);
    var writer = switch (files.streamWriter(parsed.asZ(), r4os.abi.file_stream_open_create)) {
        .writer => |v| v,
        .failure => return error.BindingStage,
    };
    var complete = false;
    defer if (!complete) {
        _ = writer.abort();
    };
    if (writer.write(bytes) != .ok or writer.finish() != .ok) return error.BindingStage;
    complete = true;
    const observed = (try readBytes(files, allocator, path, limit)) orelse return error.BindingReadback;
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, bytes)) return error.BindingReadback;
}
