//! All catalog, binding and inventory IO runs on the joined worker.
const std = @import("std");
const r = @import("r4os");
const catalog = @import("catalog_client.zig");
const state = @import("state.zig");
const m = @import("model.zig");
const view = @import("view.zig");
const backend = @import("system_update_engine");
const shortcut = @import("r4std").shortcut;
const installation = @import("installation.zig");

pub const Snapshot = struct {
    result: catalog.Result = .{},
    projection: ?view.Projection = null,
    failure: ?anyerror = null,
    pending_installation: bool = false,

    pub fn deinit(self: *Snapshot) void {
        if (self.projection) |*projection| projection.deinit();
        self.result.deinit();
        self.* = .{};
    }
};
pub const Job = struct {
    app: *r.App,
    allocator: std.mem.Allocator,
    stop: r.app_contract.StopFlag = .{},
    output: Snapshot = .{},

    pub fn entry(context: u64) callconv(.c) i32 {
        const self: *Job = @ptrFromInt(context);
        self.output = self.load();
        return 0;
    }
    fn load(self: *Job) Snapshot {
        var snapshot = Snapshot{ .result = catalog.refresh(self.app, self.allocator, &self.stop) };
        const files = self.app.files() orelse {
            snapshot.failure = error.FilesUnavailable;
            return snapshot;
        };
        snapshot.pending_installation = installation.pending(&files, self.allocator) catch |err| blk: {
            snapshot.failure = err;
            break :blk false;
        };
        const bindings = state.load(&files, self.allocator, state.default_path) catch |err| {
            snapshot.failure = err;
            return snapshot;
        };
        defer bindings.deinit();
        const inventory_bytes = state.readBytes(&files, self.allocator, "C:\\R4OS\\CONFIG\\MODULES.JSON", r.system_update_inventory.max_bytes) catch |err| {
            snapshot.failure = err;
            return snapshot;
        };
        defer if (inventory_bytes) |bytes| self.allocator.free(bytes);
        // The fixed inventory is large; never place it on the worker stack.
        const inventory = self.allocator.create(r.system_update_inventory.Inventory) catch |err| {
            snapshot.failure = err;
            return snapshot;
        };
        defer self.allocator.destroy(inventory);
        var inventory_known = false;
        if (inventory_bytes) |bytes| {
            inventory_known = r.system_update_inventory.Inventory.parse(bytes, inventory);
            if (!inventory_known) snapshot.failure = error.InventoryInvalid;
        } else snapshot.failure = error.InventoryMissing;
        if (!self.stop.requested()) {
            const value = if (snapshot.result.snapshot) |s| s.catalog else m.Catalog{ .schema_version = 1, .packages = &.{}, .unavailable = &.{} };
            snapshot.projection = view.Projection.build(self.allocator, value, bindings.value, if (inventory_known) inventory else null, if (snapshot.result.snapshot) |s| s.fresh else false) catch |err| {
                snapshot.failure = err;
                return snapshot;
            };
            verifyObserved(&files, self.allocator, &snapshot.projection.?, bindings.value) catch |err| {
                snapshot.failure = err;
            };
        } else snapshot.result.failure = .{ .reason = .cancelled };
        return snapshot;
    }
};

/// The inventory and saved bindings suggest locations; only the actual
/// bounded R4M0 metadata (and owned hash) qualifies an installed app.
pub fn verifyObserved(files: *const r.Files, allocator: std.mem.Allocator, projection: *view.Projection, bindings: m.Bindings) !void {
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);
    const a = projection.arena.allocator();
    for (projection.rows) |*row| {
        if (row.kind != .application or row.actual_path == null) continue;
        const path = r.AbsoluteFilePath.parse(row.actual_path.?) catch {
            row.status = .conflict;
            continue;
        };
        const identity = backend.asset.inspect(files, path) catch {
            row.status = .unverified;
            continue;
        };
        if (identity.kind != .r4x or !std.ascii.eqlIgnoreCase(identity.nameText(), row.target)) {
            row.status = .conflict;
            continue;
        }
        if (row.installed_version == null or !std.mem.eql(u8, identity.versionText(), row.installed_version.?)) {
            row.status = .conflict;
            continue;
        }
        if (bindings.find(row.package_id)) |binding| {
            const digest = backend.asset.digest(files, path, scratch) catch {
                row.status = .unverified;
                continue;
            };
            if (!std.ascii.eqlIgnoreCase(&digest.sha256, binding.sha256)) row.status = .conflict;
        }
    }
    // One known Desktop folder, no recursive/global file-system scan. These
    // are observed locations, not an implicit write to the component inventory.
    const desktop = try r.AbsoluteFilePath.parse("C:\\R4OS\\DESKTOP");
    switch (files.info(desktop.asZ())) {
        .missing => return,
        .failure => return error.DesktopRead,
        .value => |v| if (v.is_dir == 0) return error.DesktopRead,
    }
    var iterator = files.iterate(desktop.asZ());
    var path_buffer: [1024]u8 = undefined;
    while (true) switch (iterator.next(&path_buffer)) {
        .end => break,
        .failure => return error.DesktopRead,
        .entry => |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.path, ".LNK")) continue;
            const bytes = state.readBytes(files, allocator, entry.path, 4096) catch continue;
            if (bytes == null) continue;
            defer allocator.free(bytes.?);
            var link: shortcut.Shortcut = .{};
            link.loadFromBytes(bytes.?) catch continue;
            const path = r.AbsoluteFilePath.parse(link.targetText()) catch continue;
            const identity = backend.asset.inspect(files, path) catch continue;
            if (identity.kind != .r4x) continue;
            for (projection.rows) |*row| {
                if (row.kind != .application or row.package_index == null or !std.ascii.eqlIgnoreCase(row.target, identity.nameText())) continue;
                if (row.actual_path) |old| {
                    if (!view.samePath(old, path.bytes())) row.status = .conflict;
                    continue;
                }
                row.actual_path = try a.dupe(u8, path.bytes());
                row.proposed_path = row.actual_path;
                row.installed_version = try a.dupe(u8, identity.versionText());
                row.status = if (row.available_version != null and (r.r4u_manifest.compareVersions(row.available_version.?, identity.versionText()) orelse 0) > 0) .update else .installed;
            }
        },
    };
}
