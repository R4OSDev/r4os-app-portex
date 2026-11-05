//! Immutable, owned GUI projection. No file, network or installation effects.
const std = @import("std");
const r = @import("r4os");
const m = @import("model.zig");
pub const Tab = enum { discover, installed, updates };
pub const Status = enum { available, installed, update, pending_restart, unavailable, local, unverified, conflict };
pub const Row = struct {
    package_index: ?usize = null,
    package_id: []const u8,
    kind: ?m.Kind,
    target: []const u8,
    name: []const u8,
    description: []const u8,
    category: []const u8,
    available_version: ?[]const u8 = null,
    installed_version: ?[]const u8 = null,
    actual_path: ?[]const u8 = null,
    proposed_path: ?[]const u8 = null,
    status: Status,
    observed: bool = false,

    pub fn statusText(self: Row) []const u8 {
        return switch (self.status) {
            .available => "Verfuegbar",
            .installed => "Installiert",
            .update => "Update verfuegbar",
            .pending_restart => "Fuer Neustart vorbereitet",
            .unavailable => "Serverpaket nicht verfuegbar",
            .local => "Lokal, ohne Katalogeintrag",
            .unverified => "Gespeicherte Zuordnung: Bestand pruefen",
            .conflict => "Mehrdeutiger oder abweichender Bestand",
        };
    }
    pub fn visible(self: Row, tab: Tab, kind: m.Kind, category: ?[]const u8, query: []const u8) bool {
        if (tab == .discover and self.package_index == null and self.status != .unavailable) return false;
        if (self.kind != null and self.kind.? != kind) return false;
        if (category) |c| if (!std.mem.eql(u8, self.category, c)) return false;
        if (tab == .installed and self.actual_path == null) return false;
        if (tab == .updates and self.status != .update) return false;
        return contains(self.name, query) or contains(self.target, query) or contains(self.description, query);
    }
};
pub const Projection = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,
    categories: []const []const u8,
    fresh: bool,
    inventory_known: bool,

    pub fn deinit(self: *Projection) void {
        self.arena.deinit();
    }

    pub fn build(allocator: std.mem.Allocator, catalog: m.Catalog, bindings: m.Bindings, inventory: ?*const r.system_update_inventory.Inventory, fresh: bool) !Projection {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        for (catalog.packages, 0..) |p, pi| {
            var row = Row{ .package_index = pi, .package_id = p.package_id, .kind = p.package_type, .target = p.target, .name = p.display_name, .description = p.description, .category = p.category, .available_version = p.version, .status = .available };
            const binding = bindings.find(p.package_id);
            var found: ?r.system_update_inventory.Entry = null;
            var ambiguous = false;
            if (inventory) |inv| for (inv.entries[0..inv.count]) |entry| {
                if (entry.kind == componentKind(p.package_type) and std.ascii.eqlIgnoreCase(entry.name, p.target)) {
                    if (found != null) ambiguous = true;
                    found = entry;
                }
            };
            if (binding) |b| {
                row.actual_path = b.actual_path;
                row.installed_version = b.installed_version;
                row.status = if (found != null and b.matchesInventory(found.?)) .installed else .unverified;
                if (found != null and !b.matchesInventory(found.?)) row.status = .conflict;
            } else if (found) |entry| {
                row.actual_path = if (p.package_type == .kernel) try a.dupe(u8, entry.target) else try clientPath(a, entry.target);
                row.installed_version = entry.version;
                row.status = .installed;
            }
            if (ambiguous) row.status = .conflict;
            if (row.status == .installed and (r.r4u_manifest.compareVersions(p.version, row.installed_version.?) orelse 0) > 0) row.status = .update;
            if (row.actual_path) |actual| row.proposed_path = actual else if (p.package_type != .kernel) {
                const target = resolveNew(p, null) catch null;
                if (target) |path| row.proposed_path = try a.dupe(u8, path.bytes());
            }
            try rows.append(a, try copyRow(a, row));
        }
        for (catalog.unavailable) |unavailable| {
            const b = bindings.find(unavailable.package_id);
            for (rows.items) |row| if (std.mem.eql(u8, row.package_id, unavailable.package_id)) return error.DuplicateAvailability;
            try rows.append(a, try copyRow(a, .{ .package_id = unavailable.package_id, .kind = if (b) |v| v.package_type else null, .target = if (b) |v| v.target else "", .name = unavailable.package_id, .description = unavailable.reason, .category = "Nicht verfuegbar", .installed_version = if (b) |v| v.installed_version else null, .actual_path = if (b) |v| v.actual_path else null, .status = .unavailable }));
        }
        for (bindings.bindings) |binding| {
            var seen = false;
            for (rows.items) |row| if (std.mem.eql(u8, row.package_id, binding.package_id)) {
                seen = true;
                break;
            };
            if (!seen) {
                var status: Status = .unverified;
                if (inventory) |inv| for (inv.entries[0..inv.count]) |entry| {
                    if (binding.matchesInventory(entry)) status = .local;
                };
                try rows.append(a, try copyRow(a, .{ .package_id = binding.package_id, .kind = binding.package_type, .target = binding.target, .name = binding.target, .description = "Gespeicherte Katalogbindung, aktuell kein Servereintrag", .category = "Lokal", .installed_version = binding.installed_version, .actual_path = binding.actual_path, .status = status }));
            }
        }
        if (inventory) |inv| for (inv.entries[0..inv.count]) |entry| {
            const kind = inventoryKind(entry) orelse continue;
            var seen = false;
            for (rows.items) |row| if (row.actual_path != null and samePath(entry.target, row.actual_path.?)) {
                seen = true;
                break;
            };
            if (!seen) try rows.append(a, try copyRow(a, .{ .package_id = "", .kind = kind, .target = entry.name, .name = entry.name, .description = "Installierte Komponente ohne aktuelle Katalogzuordnung", .category = "Lokal", .installed_version = entry.version, .actual_path = if (kind == .kernel) try a.dupe(u8, entry.target) else try clientPath(a, entry.target), .status = .local }));
        };
        std.mem.sort(Row, rows.items, {}, less);
        var categories: std.ArrayList([]const u8) = .empty;
        for (rows.items) |row| {
            var exists = false;
            for (categories.items) |c| if (std.mem.eql(u8, c, row.category)) {
                exists = true;
                break;
            };
            if (!exists) try categories.append(a, row.category);
        }
        std.mem.sort([]const u8, categories.items, {}, struct {
            fn lt(_: void, l: []const u8, rr: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(l, rr);
            }
        }.lt);
        return .{ .arena = arena, .rows = try rows.toOwnedSlice(a), .categories = try categories.toOwnedSlice(a), .fresh = fresh, .inventory_known = inventory != null };
    }
};

fn copyRow(a: std.mem.Allocator, value: Row) !Row {
    var row = value;
    inline for (.{ "package_id", "target", "name", "description", "category" }) |field| @field(row, field) = try a.dupe(u8, @field(value, field));
    inline for (.{ "available_version", "installed_version", "actual_path", "proposed_path" }) |field| if (@field(value, field)) |text| {
        @field(row, field) = try a.dupe(u8, text);
    };
    return row;
}
fn less(_: void, l: Row, rr: Row) bool {
    if (std.ascii.eqlIgnoreCase(l.name, rr.name)) return std.mem.order(u8, l.package_id, rr.package_id) == .lt;
    return std.ascii.lessThanIgnoreCase(l.name, rr.name);
}
fn contains(haystack: []const u8, query: []const u8) bool {
    if (query.len > haystack.len) return false;
    for (0..haystack.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..query.len], query)) return true;
    return false;
}
pub fn componentKind(kind: m.Kind) r.r4u_manifest.ComponentKind {
    return switch (kind) {
        .application => .r4x,
        .library => .r4l,
        .kernel => .kernel,
    };
}
fn inventoryKind(entry: r.system_update_inventory.Entry) ?m.Kind {
    return switch (entry.kind) {
        .kernel => .kernel,
        .r4l => .library,
        .r4x => if (std.ascii.startsWithIgnoreCase(entry.target, "/R4OS/SOFTWARE/") or std.ascii.startsWithIgnoreCase(entry.target, "C:\\R4OS\\SOFTWARE\\")) .application else null,
        else => null,
    };
}
pub fn clientPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var normalized: r.AbsoluteFilePath = undefined;
    if (path.len > 0 and path[0] == '/') {
        const drive = try std.fmt.allocPrint(a, "C:{s}", .{path});
        normalized = try r.AbsoluteFilePath.parse(drive);
    } else normalized = try r.AbsoluteFilePath.parse(path);
    return a.dupe(u8, normalized.bytes());
}
pub fn samePath(l: []const u8, rr: []const u8) bool {
    const left = if (l.len >= 3 and std.ascii.toUpper(l[0]) == 'C' and l[1] == ':') l[2..] else l;
    const right = if (rr.len >= 3 and std.ascii.toUpper(rr[0]) == 'C' and rr[1] == ':') rr[2..] else rr;
    return r.r4u_manifest.targetEquals(left, right);
}
/// Directory proposals add exactly the original asset leaf. File proposals
/// preserve that leaf; boot paths can only be supplied by the boot owner.
pub fn resolveNew(package: m.Package, customized: ?[]const u8) !r.AbsoluteFilePath {
    if (package.package_type == .kernel) return error.BootPlanRequired;
    const raw = customized orelse package.installation.path orelse return error.MissingDestination;
    var buffer: [r.path.file_path_max + 4]u8 = undefined;
    const source = if (customized == null and raw.len > 0 and raw[0] == '/') try std.fmt.bufPrint(&buffer, "C:{s}", .{raw}) else raw;
    const base = try r.AbsoluteFilePath.parse(source);
    const asset = package.artifact() orelse return error.InvalidArtifact;
    if (package.installation.path_kind == .file) {
        const leaf = base.bytes()[(std.mem.lastIndexOfScalar(u8, base.bytes(), '\\') orelse return error.MissingDestination) + 1 ..];
        if (!std.ascii.eqlIgnoreCase(leaf, asset.name)) return error.OriginalFilenameRequired;
        return base;
    }
    var joined: [r.path.file_path_max + 1]u8 = undefined;
    return r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&joined, "{s}\\{s}", .{ base.bytes(), asset.name }));
}
