const std = @import("std");
const model = @import("model.zig");
const state = @import("state.zig");
const policy = @import("catalog_policy.zig");
pub const path = "C:\\R4OS\\DATA\\PORTEX\\CATALOG.JSON";
pub const max_catalog_bytes = 4 * 1024 * 1024;
pub const max_cache_bytes = 8 * 1024 * 1024;
pub const Wire = struct { schema_version: u32, origin: []const u8, profile: []const u8, etag: ?[]const u8, body: []const u8 };

/// One self-owned arena; no slice borrows a temporary HTTP or file buffer.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    origin: []const u8,
    profile: []const u8,
    etag: ?[]const u8,
    body: []const u8,
    catalog: model.Catalog,
    fresh: bool = false,
    cached: bool = false,
    cache_saved: bool = false,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }

    pub fn init(allocator: std.mem.Allocator, origin: []const u8, profile: []const u8, etag: ?[]const u8, body: []const u8) !Snapshot {
        if (body.len == 0 or body.len > max_catalog_bytes) return error.CatalogTooLarge;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copied = try a.dupe(u8, body);
        const catalog = try std.json.parseFromSliceLeaky(model.Catalog, a, copied, .{ .ignore_unknown_fields = true });
        try catalog.validate();
        const copied_origin = try a.dupe(u8, origin);
        const copied_profile = try a.dupe(u8, profile);
        const copied_etag = if (etag) |tag| if (policy.validEtag(tag)) try a.dupe(u8, tag) else null else null;
        return .{ .arena = arena, .origin = copied_origin, .profile = copied_profile, .etag = copied_etag, .body = copied, .catalog = catalog };
    }

    pub fn load(files: anytype, allocator: std.mem.Allocator, origin: []const u8, profile: []const u8) !?Snapshot {
        const bytes = (try state.readBytes(files, allocator, path, max_cache_bytes)) orelse return null;
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
        defer parsed.deinit();
        const wire = parsed.value;
        if (wire.schema_version != 1) return error.UnsupportedCacheSchema;
        if (!std.mem.eql(u8, wire.origin, origin) or !std.mem.eql(u8, wire.profile, profile)) return null;
        var result = try Snapshot.init(allocator, origin, profile, wire.etag, wire.body);
        result.cached = true;
        result.cache_saved = true;
        return result;
    }

    pub fn save(self: *Snapshot, files: anytype, allocator: std.mem.Allocator) !void {
        const bytes = try std.json.Stringify.valueAlloc(allocator, Wire{ .schema_version = 1, .origin = self.origin, .profile = self.profile, .etag = self.etag, .body = self.body }, .{});
        defer allocator.free(bytes);
        try state.writeBytes(files, allocator, path, bytes, max_cache_bytes);
        self.cache_saved = true;
    }
};
