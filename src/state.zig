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
    const bytes = try read(files, allocator, path);
    defer if (bytes) |b| allocator.free(b);
    return model.Bindings.parse(allocator, bytes orelse "{\"schema_version\":1,\"bindings\":[]}");
}

fn read(files: anytype, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const parsed_path = try r4os.AbsoluteFilePath.parse(path);
    const info = switch (files.info(parsed_path.asZ())) {
        .value => |v| v,
        .missing => return null,
        .failure => return error.BindingRead,
    };
    if (info.is_dir != 0 or info.size == 0 or info.size > max_bytes) return error.BindingSize;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
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
    if (bytes.len > max_bytes) return error.BindingSize;
    const target = try r4os.AbsoluteFilePath.parse(path);
    const staged_name = try std.fmt.allocPrint(allocator, "{s}.NEW", .{path});
    defer allocator.free(staged_name);
    const backup_name = try std.fmt.allocPrint(allocator, "{s}.BAK", .{path});
    defer allocator.free(backup_name);
    const staged = try r4os.AbsoluteFilePath.parse(staged_name);
    const backup = try r4os.AbsoluteFilePath.parse(backup_name);
    const leftover = try read(files, allocator, staged_name);
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
    const observed = (try read(files, allocator, path)) orelse return error.BindingReadback;
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, bytes)) return error.BindingReadback;
}
