const std = @import("std");
const m = @import("model.zig");
const j = @import("job.zig");
const allocator = std.testing.allocator;
const sha = "a" ** 64;
const state = @import("state.zig");

fn package() m.Package {
    return .{ .package_id = "gh-123-APP", .package_type = .application, .target = "APP", .format = .R4X, .display_name = "A new name", .category = "Tools", .version = "0.1.10", .release = .{ .id = "18446744073709551617", .tag = "v0.1.10", .commit = "b" ** 40 }, .installation = .{ .role = .application, .path = "C:\\Changed", .path_kind = .directory, .activation = .client_managed, .requires_client_plan = false }, .assets = &.{.{ .asset_id = "18446744073709551618", .name = "APP.R4X", .role = "artifact", .size_bytes = 12, .sha256 = sha, .download_url = "/api/v1/packages/gh-123-APP/files/18446744073709551618" }} };
}
fn binding() m.Binding {
    return .{ .package_id = "gh-123-APP", .package_type = .application, .target = "APP", .installed_version = "0.1.9", .release_id = "10", .asset_id = "20", .sha256 = sha, .actual_path = "C:\\Chosen\\APP.R4X" };
}

test "catalog identity and numeric versions survive rename, changed paths and large string IDs" {
    const p = package();
    try p.validate();
    const json = try std.json.Stringify.valueAlloc(allocator, m.Catalog{ .schema_version = 1, .packages = &.{p}, .unavailable = &.{} }, .{});
    defer allocator.free(json);
    const parsed = try m.Catalog.parse(allocator, json);
    defer parsed.deinit();
    const saved = try (m.Bindings{ .bindings = &.{binding()} }).encode(allocator);
    defer allocator.free(saved);
    const reopened = try m.Bindings.parse(allocator, saved);
    defer reopened.deinit();
    const b = reopened.value.find(p.package_id).?.*;
    try std.testing.expect(m.updateAvailable(parsed.value.packages[0], b));
    try std.testing.expectEqualStrings("18446744073709551617", parsed.value.packages[0].release.id);
    try std.testing.expectEqualStrings("C:\\Chosen\\APP.R4X", try m.destination(p, b, "C:\\Other"));
    try std.testing.expect(!b.matchesInventory(.{ .name = "OTHER", .kind = .r4x, .version = b.installed_version, .target = b.actual_path }));
    try std.testing.expect(!b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = "0.1.8", .target = b.actual_path }));
    try std.testing.expect(b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = b.installed_version, .target = b.actual_path }));
    try std.testing.expect(b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = b.installed_version, .target = "/Chosen/APP.R4X" }));
    try std.testing.expect(!b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = b.installed_version, .target = "D:\\Chosen\\APP.R4X" }));
}

test "all package types retain their own destination and boot activation rules" {
    var p = package();
    try std.testing.expectEqualStrings("C:\\Custom", try m.destination(p, null, "C:\\Custom"));
    p.package_type = .library;
    p.format = .R4L;
    p.installation = .{ .role = .runtime_library, .path = "/R4OS/LIBS/TEST.R4L", .path_kind = .file, .activation = .client_managed, .requires_client_plan = false };
    try p.validate();
    try std.testing.expectEqualStrings("/R4OS/LIBS/TEST.R4L", try m.destination(p, null, null));
    p.package_type = .kernel;
    p.format = .ELF;
    p.installation = .{ .role = .boot_kernel, .path = null, .path_kind = .file, .activation = .boot_configuration, .requires_client_plan = true };
    try p.validate();
    try std.testing.expectError(error.BootPlanRequired, m.destination(p, null, "/guessed"));
    p.installation.requires_client_plan = false;
    try std.testing.expectError(error.MissingClientPlan, p.validate());
}

test "bad schemas, ambiguous artifacts, duplicate bindings and partial JSON never become empty success" {
    try std.testing.expectError(error.UnsupportedSchema, m.Catalog.parse(allocator, "{\"schema_version\":2,\"packages\":[],\"unavailable\":[]}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, m.Bindings.parse(allocator, "{"));
    try std.testing.expectError(error.MissingField, m.Bindings.parse(allocator, "{}"));
    try std.testing.expectError(error.MissingField, m.Bindings.parse(allocator, "{\"schema_version\":1}"));
    try std.testing.expectError(error.DuplicateBinding, (m.Bindings{ .bindings = &.{ binding(), binding() } }).validate());
    var p = package();
    p.assets = &.{ p.assets[0], p.assets[0] };
    try std.testing.expectError(error.InvalidArtifact, p.validate());
}

test "cancel requests and stale worker receipts cannot report durable installation completion" {
    const token: j.Token = .{ .request = 1, .process = 17, .generation = 4 };
    var job: j.Job = .{ .token = token };
    try std.testing.expect(!job.observe(token, .{ .backend_job = 0, .phase = .installed }));
    try std.testing.expect(job.observe(token, .{ .backend_job = 9, .phase = .staging }));
    job.requestCancel();
    try std.testing.expectEqual(j.Phase.staging, job.phase);
    try std.testing.expect(!job.observe(.{ .request = 1, .process = 17, .generation = 5 }, .{ .backend_job = 9, .phase = .installed }));
    try std.testing.expect(!job.observe(token, .{ .backend_job = 10, .phase = .installed }));
    try std.testing.expect(job.observe(token, .{ .backend_job = 9, .phase = .pending_restart }));
    try std.testing.expect(!job.terminal());
    try std.testing.expect(job.observe(token, .{ .backend_job = 9, .phase = .installed }));
    try std.testing.expect(!job.observe(token, .{ .backend_job = 9, .phase = .downloading }));
}

const Disk = struct {
    current: [4096]u8 = undefined,
    stage: [4096]u8 = undefined,
    current_len: usize = 0,
    stage_len: usize = 0,
    fail_commit: bool = false,
    writes: usize = 0,

    fn staged(path: anytype) bool {
        return std.mem.endsWith(u8, path.bytes(), ".NEW");
    }
    pub fn info(self: *Disk, path: anytype) union(enum) { value: struct { size: u64, is_dir: u8 = 0 }, missing, failure: i32 } {
        const n = if (staged(path)) self.stage_len else self.current_len;
        return if (n == 0) .missing else .{ .value = .{ .size = n } };
    }
    pub fn read(self: *Disk, path: anytype, out: []u8) union(enum) { bytes: u32, end, failure: i32 } {
        const bytes = if (staged(path)) self.stage[0..self.stage_len] else self.current[0..self.current_len];
        if (out.len != bytes.len) return .{ .failure = -1 };
        @memcpy(out, bytes);
        return .{ .bytes = @intCast(bytes.len) };
    }
    const Writer = struct {
        disk: *Disk,
        pub fn write(self: *Writer, bytes: []const u8) enum { ok, failure } {
            if (bytes.len > self.disk.stage.len) return .failure;
            @memcpy(self.disk.stage[0..bytes.len], bytes);
            self.disk.stage_len = bytes.len;
            self.disk.writes += 1;
            return .ok;
        }
        pub fn finish(_: *Writer) enum { ok, failure } {
            return .ok;
        }
        pub fn abort(self: *Writer) enum { ok, failure } {
            self.disk.stage_len = 0;
            return .ok;
        }
    };
    pub fn streamWriter(self: *Disk, _: anytype, _: u32) union(enum) { writer: Writer, failure: i32 } {
        return .{ .writer = .{ .disk = self } };
    }
    pub fn replaceAtomic(self: *Disk, _: anytype, _: anytype, _: anytype, _: struct {}) enum { ok, failure } {
        if (self.fail_commit) return .failure;
        @memcpy(self.current[0..self.stage_len], self.stage[0..self.stage_len]);
        self.current_len = self.stage_len;
        self.stage_len = 0;
        return .ok;
    }
};

test "binding storage preserves old data on failed commit and resumes its exact completed stage" {
    var disk: Disk = .{};
    const empty = try state.load(&disk, allocator, state.default_path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.bindings.len);
    try state.save(&disk, allocator, state.default_path, .{});
    const original = try allocator.dupe(u8, disk.current[0..disk.current_len]);
    defer allocator.free(original);
    disk.fail_commit = true;
    try std.testing.expectError(error.BindingCommit, state.save(&disk, allocator, state.default_path, .{ .bindings = &.{binding()} }));
    try std.testing.expectEqualSlices(u8, original, disk.current[0..disk.current_len]);
    const writes = disk.writes;
    disk.fail_commit = false;
    try state.save(&disk, allocator, state.default_path, .{ .bindings = &.{binding()} });
    try std.testing.expectEqual(writes, disk.writes);
    const reopened = try state.load(&disk, allocator, state.default_path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings(binding().actual_path, reopened.value.find(binding().package_id).?.actual_path);
}
