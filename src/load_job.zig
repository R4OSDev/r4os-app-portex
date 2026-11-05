//! All catalog, binding and inventory IO runs on the joined worker.
const std = @import("std");
const r = @import("r4os");
const catalog = @import("catalog_client.zig");
const state = @import("state.zig");
const m = @import("model.zig");
const view = @import("view.zig");

pub const Snapshot = struct {
    result: catalog.Result = .{},
    projection: ?view.Projection = null,
    failure: ?anyerror = null,

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
        } else snapshot.result.failure = .{ .reason = .cancelled };
        return snapshot;
    }
};
