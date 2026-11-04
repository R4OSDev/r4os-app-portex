//! Catalog and catalog-to-installation bindings. MODULES.JSON remains the
//! installed component inventory; a saved binding alone never proves install.
const std = @import("std");
const r4os = @import("r4os");
const versions = r4os.r4u_manifest;
pub const Allocator = std.mem.Allocator;
pub const Kind = enum { application, library, kernel };
pub const Format = enum { R4X, R4L, ELF };
pub const PathKind = enum { directory, file };
pub const Activation = enum { client_managed, boot_configuration };
pub const Role = enum { application, runtime_library, boot_kernel };
pub const Release = struct { id: []const u8, tag: []const u8, commit: []const u8 };
pub const Asset = struct {
    asset_id: []const u8,
    name: []const u8,
    role: []const u8,
    size_bytes: u64,
    sha256: []const u8,
    download_url: []const u8,
};
pub const Installation = struct {
    role: Role,
    path: ?[]const u8,
    path_kind: PathKind,
    activation: Activation,
    requires_client_plan: bool,
};
pub const Package = struct {
    package_id: []const u8,
    package_type: Kind,
    target: []const u8,
    format: Format,
    display_name: []const u8,
    description: []const u8 = "",
    category: []const u8,
    version: []const u8,
    release: Release,
    installation: Installation,
    assets: []const Asset,
    // Kept as data; deliberately no dependency/compatibility admission policy.
    compatibility: ?std.json.Value = null,
    runtime_dependencies: ?std.json.Value = null,
    declared_imports: ?std.json.Value = null,
    provides: ?std.json.Value = null,

    pub fn artifact(self: Package) ?*const Asset {
        var found: ?*const Asset = null;
        for (self.assets) |*asset| if (std.mem.eql(u8, asset.role, "artifact")) {
            if (found != null) return null;
            found = asset;
        };
        return found;
    }

    pub fn validate(self: Package) !void {
        if (!token(self.package_id) or !token(self.target) or !label(self.display_name) or
            !label(self.category) or !std.unicode.utf8ValidateSlice(self.description) or
            !versions.validSemanticVersion(self.version) or !decimal(self.release.id) or
            !hex(self.release.commit, 40)) return error.InvalidPackage;
        const asset = self.artifact() orelse return error.InvalidArtifact;
        if (!decimal(asset.asset_id) or !fileName(asset.name) or !hex(asset.sha256, 64) or
            asset.size_bytes == 0 or asset.download_url.len == 0) return error.InvalidArtifact;
        const i = self.installation;
        switch (self.package_type) {
            .application => if (self.format != .R4X or i.role != .application or i.path_kind != .directory or
                i.activation != .client_managed or i.path == null) return error.InvalidInstallation,
            .library => if (self.format != .R4L or i.role != .runtime_library or i.path_kind != .file or
                i.activation != .client_managed or i.path == null) return error.InvalidInstallation,
            .kernel => if (self.format != .ELF or i.role != .boot_kernel or i.path_kind != .file or
                i.activation != .boot_configuration) return error.InvalidInstallation,
        }
        if (i.path) |path| {
            if (!pathText(path)) return error.InvalidInstallation;
        } else if (!i.requires_client_plan) return error.MissingClientPlan;
    }
};
pub const Unavailable = struct { package_id: []const u8, reason: []const u8 };
pub const Catalog = struct {
    schema_version: u32,
    packages: []const Package,
    unavailable: []const Unavailable,

    pub fn parse(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Catalog) {
        const parsed = try std.json.parseFromSlice(Catalog, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        errdefer parsed.deinit();
        if (parsed.value.schema_version != 1) return error.UnsupportedSchema;
        for (parsed.value.packages, 0..) |p, n| {
            try p.validate();
            for (parsed.value.packages[0..n]) |old| if (std.mem.eql(u8, old.package_id, p.package_id)) return error.DuplicatePackage;
        }
        for (parsed.value.unavailable) |p| {
            if (!token(p.package_id) or !label(p.reason)) return error.InvalidUnavailable;
            for (parsed.value.packages) |available| if (std.mem.eql(u8, available.package_id, p.package_id)) return error.PackageAvailabilityConflict;
        }
        return parsed;
    }

    pub fn find(self: Catalog, id: []const u8) ?*const Package {
        for (self.packages) |*p| if (std.mem.eql(u8, p.package_id, id)) return p;
        return null;
    }
};

pub const Link = struct { path: []const u8, sha256: []const u8 };
pub const Binding = struct {
    package_id: []const u8,
    package_type: Kind,
    target: []const u8,
    installed_version: []const u8,
    release_id: []const u8,
    asset_id: []const u8,
    sha256: []const u8,
    actual_path: []const u8,
    links: []const Link = &.{},

    pub fn validate(self: Binding) !void {
        if (!token(self.package_id) or !token(self.target) or !versions.validSemanticVersion(self.installed_version) or
            !decimal(self.release_id) or !decimal(self.asset_id) or !hex(self.sha256, 64) or
            !pathText(self.actual_path)) return error.InvalidBinding;
        for (self.links) |link| if (!pathText(link.path) or !hex(link.sha256, 64)) return error.InvalidBinding;
    }

    pub fn matchesInventory(self: Binding, entry: r4os.system_update_inventory.Entry) bool {
        const kind: versions.ComponentKind = switch (self.package_type) {
            .application => .r4x,
            .library => .r4l,
            .kernel => .kernel,
        };
        return entry.kind == kind and std.ascii.eqlIgnoreCase(entry.name, self.target) and
            sameTarget(entry.target, self.actual_path) and std.mem.eql(u8, entry.version, self.installed_version);
    }
};

pub const Bindings = struct {
    schema_version: u32 = 1,
    bindings: []const Binding = &.{},

    pub fn validate(self: Bindings) !void {
        if (self.schema_version != 1) return error.UnsupportedBindingsSchema;
        for (self.bindings, 0..) |binding, n| {
            try binding.validate();
            for (self.bindings[0..n]) |old| {
                if (std.mem.eql(u8, old.package_id, binding.package_id) or sameTarget(old.actual_path, binding.actual_path)) return error.DuplicateBinding;
            }
        }
    }

    pub fn encode(self: Bindings, allocator: Allocator) ![]u8 {
        try self.validate();
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn parse(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Bindings) {
        // Defaults are useful to construct an empty value, but are not a wire
        // migration: a missing schema or list must never erase saved bindings.
        const Wire = struct { schema_version: u32, bindings: []const Binding };
        const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const value = Bindings{ .schema_version = parsed.value.schema_version, .bindings = parsed.value.bindings };
        try value.validate();
        return .{ .arena = parsed.arena, .value = value };
    }

    pub fn find(self: Bindings, id: []const u8) ?*const Binding {
        for (self.bindings) |*b| if (std.mem.eql(u8, b.package_id, id)) return b;
        return null;
    }
};

/// The bound existing path wins. Missing kernel targets require the boot owner.
pub fn destination(package: Package, binding: ?Binding, customized: ?[]const u8) ![]const u8 {
    if (binding) |b| {
        if (!std.mem.eql(u8, b.package_id, package.package_id) or b.package_type != package.package_type or
            !std.ascii.eqlIgnoreCase(b.target, package.target)) return error.BindingConflict;
        return b.actual_path;
    }
    if (package.package_type == .kernel) return error.BootPlanRequired;
    return customized orelse package.installation.path orelse error.MissingDestination;
}

pub fn updateAvailable(package: Package, binding: Binding) bool {
    if (!std.mem.eql(u8, package.package_id, binding.package_id)) return false;
    return (versions.compareVersions(package.version, binding.installed_version) orelse return false) > 0;
}

fn label(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}
fn token(value: []const u8) bool {
    if (!label(value)) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}
fn decimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn hex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}
fn fileName(value: []const u8) bool {
    return label(value) and std.mem.indexOfAny(u8, value, "/\\:") == null and !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}
fn pathText(value: []const u8) bool {
    return label(value) and (value[0] == '/' or (value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and (value[2] == '\\' or value[2] == '/')));
}

fn sameTarget(left: []const u8, right: []const u8) bool {
    // Inventory image paths are rooted on C:. Never erase another volume.
    const L = struct {
        fn image(path: []const u8) []const u8 {
            return if (path.len >= 3 and std.ascii.toUpper(path[0]) == 'C' and path[1] == ':' and
                (path[2] == '/' or path[2] == '\\')) path[2..] else path;
        }
    };
    return versions.targetEquals(L.image(left), L.image(right));
}
