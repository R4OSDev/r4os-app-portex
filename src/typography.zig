//! Portex typography. The application owns each face and its bounded caches.
const std = @import("std");
const r = @import("r4os");
const font = @import("app_fonts");
const g = r.gui;

pub fn theme() g.Style {
    return .{ .background = 0x1b1824, .surface = 0x262232, .soft = 0x302a40,
        .line = 0x443b54, .text = 0xf0edf6, .muted = 0xbbb2c8,
        .accent = 0xd1b6ff, .accent_text = 0x241833, .tint = 0x40324f,
        .hover = 0x3a3249, .pressed = 0x4e3f61, .disabled = 0x91879d,
        .radius = 5, .gap = 8, .padding = 9 };
}
const Face = enum { regular, semibold, mono };
const Spec = struct { face: Face, size: u32 };
fn spec(role: g.TextRole) Spec {
    return switch (role) {
        .body => .{ .face = .regular, .size = 14 },
        .caption => .{ .face = .regular, .size = 12 },
        .heading => .{ .face = .semibold, .size = 17 },
        .display => .{ .face = .semibold, .size = 26 },
    };
}
pub const Text = struct {
    store: ?font.FaceStore = null,
    faces: [3]?font.FaceHandle = @splat(null),
    roles: [4]?g.FontMetrics = @splat(null),
    mono_metrics: ?g.FontMetrics = null,
    runs: g.FontRuns(font),

    pub fn init(app: *r.App2, allocator: std.mem.Allocator) Text {
        var self = Text{ .runs = .{ .allocator = allocator } };
        const context = font.FontContext.init2(app.startContext()) orelse return self;
        self.store = font.FaceStore.init(context, allocator, .{ .max_cached_glyphs = 512, .max_cached_bytes = 512 * 1024 }) catch return self;
        const files = [_][]const u8{ @embedFile("fonts/Inter-Regular.woff2"), @embedFile("fonts/Inter-SemiBold.woff2"), @embedFile("fonts/IBMPlexMono-Regular.ttf") };
        for (files, &self.faces) |bytes, *handle| handle.* = self.store.?.openCopy(bytes, 0) catch null;
        for ([_]g.TextRole{ .body, .caption, .heading, .display }) |role| {
            const style = spec(role);
            const handle = self.faces[@intFromEnum(style.face)] orelse continue;
            const m = self.store.?.faceMetricsAt(handle, style.size) catch continue;
            self.roles[@intFromEnum(role)] = .{ .height = @max(1, pixels(m.height)), .baseline = pixels(m.baseline),
                .line_height = @max(1, pixels(m.line_height)), .max_advance = @max(1, @divTrunc(@as(i32, @intCast(style.size)), 2) + 1) };
        }
        if (self.faces[@intFromEnum(Face.mono)]) |handle| {
            if (self.store.?.faceMetricsAt(handle, 13)) |m| {
                self.mono_metrics = .{ .height = @max(1, pixels(m.height)), .baseline = pixels(m.baseline), .line_height = @max(1, pixels(m.line_height)) };
            } else |_| {}
        }
        return self;
    }
    fn pixels(n: i32) i32 { return @divFloor(n + 32, 64); }
    pub fn deinit(self: *Text) void {
        self.runs.deinit();
        if (self.store) |*store| store.deinit();
    }
    fn owner(ptr: *anyopaque) *Text { return @ptrCast(@alignCast(ptr)); }
    fn metrics(ptr: *anyopaque, role: g.TextRole) ?g.FontMetrics { return owner(ptr).roles[@intFromEnum(role)]; }
    fn measure(ptr: *anyopaque, role: g.TextRole, value: []const u8) ?i32 {
        if (value.len == 0) return 0;
        const self = owner(ptr);
        const style = spec(role);
        const face = self.faces[@intFromEnum(style.face)] orelse return null;
        const run = self.runs.prepare(&self.store.?, face, style.size, 65536, value) catch return null;
        return run.advance;
    }
    fn draw(ptr: *anyopaque, canvas: g.Canvas, role: g.TextRole, area: g.Rect, value: []const u8, alignment: g.Align, color: u32) ?i32 {
        return owner(ptr).paint(canvas, spec(role), area, value, alignment, color, metrics(ptr, role) orelse return null);
    }
    fn paint(self: *Text, canvas: g.Canvas, style: Spec, area: g.Rect, value: []const u8, align_: g.Align, color: u32, m: g.FontMetrics) ?i32 {
        if (area.isEmpty() or value.len == 0) return 0;
        const face = self.faces[@intFromEnum(style.face)] orelse return null;
        const run = self.runs.prepare(&self.store.?, face, style.size, area.w, value) catch return null;
        const baseline = area.y + @max(0, @divTrunc(area.h - m.line_height, 2)) + m.baseline;
        return run.drawChecked(canvas, area.x, baseline, area.w, align_, color);
    }
    pub fn technical(self: *Text, canvas: g.Canvas, area: g.Rect, value: []const u8, color: u32, bg: u32) bool {
        const m = self.mono_metrics orelse canvas.font;
        if (self.paint(canvas, .{ .face = .mono, .size = 13 }, area, value, .left, color, m)) |result| return result >= 0;
        var bytes: [512]u8 = undefined;
        return canvas.withFontId(canvas.font.id).label(.{ .rect = area, .text = value, .fg = color, .bg = bg }, &bytes) >= 0;
    }
    pub fn bind(self: *Text, canvas: g.Canvas) g.Canvas {
        return canvas.withControlText(.{ .context = self, .metrics = metrics, .width = measure, .draw = draw });
    }
};
