//! Native composition of public SDK controls. The Desktop owns outer chrome.
const std = @import("std");
const r = @import("r4os");
const g = r.gui;
const v = @import("view.zig");
const m = @import("model.zig");
const jobs = @import("job.zig");
const load = @import("load_job.zig");
const catalog = @import("catalog_client.zig");
const download = @import("download.zig");
const installation = @import("installation.zig");
const updates = @import("update_queue.zig");
const uninstall = @import("uninstall.zig");
const tabs = [_]g.TabItem{ .{ .text = "Entdecken" }, .{ .text = "Meine Software" }, .{ .text = "Updates" } };
const kinds = [_][:0]const u8{ "Apps", "Libraries", "Kernel" };
const focus_items = [_]g.FocusItem{ .{}, .{}, .{}, .{}, .{}, .{} };
const Action = union(enum) { tab: usize, kind: usize, search, category_toggle, category: usize, refresh, cancel, resume_install, queue_details, adopt, previous, next, row: usize, detail_close, customize, path_field, path_apply, path_cancel, download, install, update, uninstall, remove_confirm, remove_cancel, remove_abort, update_all };
pub const InstallRequest = struct { package_index: usize, destination: ?r.AbsoluteFilePath, adopt: bool = false, replace: bool = false };
const Hit = struct { action: Action, rect: g.Rect };
const Custom = struct { id: []u8, destination: r.AbsoluteFilePath };

/// Command keys are bytes; a Unicode scalar must never become a command
/// merely because its low byte is Tab, Escape or Enter.
pub fn navigationKey(message: r.app_gui.KeyMessage) u8 {
    if (message.codepoint > 0xff) return 0;
    const value = if (message.codepoint == 0) message.key else @as(u8, @intCast(message.codepoint));
    return if (value == '\n') g.Key.enter else value;
}

pub const Ui = struct {
    window: *r.Window,
    allocator: std.mem.Allocator,
    snapshot: *const load.Snapshot,
    style: g.Style,
    tab: v.Tab = .discover,
    kind: m.Kind = .application,
    search: g.TextField(256) = .{},
    path_field: g.TextField(r.path.file_path_max + 1) = .{},
    path_error: ?anyerror = null,
    category_index: usize = 0,
    category_open: bool = false,
    category_first: usize = 0,
    selected: ?usize = null,
    first: usize = 0,
    visible_count: usize = 0,
    page_size: usize = 1,
    detail: bool = false,
    customizing: bool = false,
    adopting: bool = false,
    removing: bool = false,
    remove_requested: ?usize = null,
    remove_resume: bool = false,
    remove_abort: bool = false,
    remove_progress: ?*const uninstall.Progress = null,
    dirty: bool = true,
    active: bool = false,
    busy: bool = false,
    reload_requested: bool = false,
    cancel_requested: bool = false,
    download_requested: ?usize = null,
    install_requested: ?InstallRequest = null,
    update_all_requested: bool = false,
    update_progress: ?*const updates.Progress = null,
    showing_queue: bool = false,
    queue_first: usize = 0,
    resume_requested: bool = false,
    restart_requested: bool = false,
    installation_progress: ?*const installation.Progress = null,
    download_progress: ?*const download.Progress = null,
    focus: g.FocusState = .{ .index = 2 },
    hover: ?Action = null,
    pressed: ?Action = null,
    capture: g.MouseCapture = .{},
    native_capture: r.abi.GuiPointerCaptureHandle = .{},
    hits: [64]Hit = undefined,
    hit_count: usize = 0,
    customs: std.ArrayList(Custom) = .empty,
    capabilities: jobs.Capabilities = .{},

    pub fn deinit(self: *Ui) void {
        self.release();
        for (self.customs.items) |item| self.allocator.free(item.id);
        self.customs.deinit(self.allocator);
    }
    pub fn release(self: *Ui) void {
        self.capture.clear();
        self.pressed = null;
        if (self.native_capture.id != 0) _ = self.window.pointerRelease(&self.native_capture);
        self.native_capture = .{};
    }
    fn acquire(self: *Ui) bool {
        var identity: r.abi.GuiPointerWindowIdentity = .{};
        return self.window.pointerIdentity(&identity) == 0 and self.window.pointerCapture(&identity, r.abi.gui_pointer_mode_drag, &self.native_capture) == 0;
    }
    fn same(left: ?Action, right: Action) bool {
        return if (left) |value| std.meta.eql(value, right) else false;
    }
    fn hit(self: *Ui, action: Action, rect: g.Rect, enabled: bool) bool {
        if (!enabled) return true;
        if (self.hit_count >= self.hits.len) return false;
        self.hits[self.hit_count] = .{ .action = action, .rect = rect };
        self.hit_count += 1;
        return true;
    }
    fn at(self: *const Ui, x: i32, y: i32) ?Action {
        var n = self.hit_count;
        while (n > 0) {
            n -= 1;
            if (self.hits[n].rect.contains(x, y)) return self.hits[n].action;
        }
        return null;
    }
    fn label(_: *Ui, canvas: g.Canvas, rect: g.Rect, text: []const u8, fg: u32, bg: u32) bool {
        var scratch: [1024]u8 = undefined;
        return canvas.label(.{ .rect = rect, .text = text, .fg = fg, .bg = bg }, &scratch) >= 0;
    }
    fn button(self: *Ui, canvas: g.Canvas, action: Action, rect: g.Rect, text: []const u8, enabled: bool, primary: bool, focused: bool) bool {
        var scratch: [512]u8 = undefined;
        const control = g.Button{ .rect = rect, .text = text, .state = if (!enabled) .disabled else if (same(self.pressed, action)) .pressed else if (same(self.hover, action)) .hover else .normal, .focused = self.active and focused, .is_default = primary };
        return control.draw(canvas, &scratch) >= 0 and self.hit(action, rect, enabled);
    }
    fn projection(self: *const Ui) ?*const v.Projection {
        if (self.snapshot.projection) |*p| return p;
        return null;
    }
    pub fn pendingUpdates(self: *const Ui) bool {
        return if (self.snapshot.update_queue) |saved| !saved.value.completed() else false;
    }
    pub fn pendingRemoval(self: *const Ui) bool {
        return if (self.snapshot.removal) |saved| !saved.value.terminal() else false;
    }
    fn restartReady(self: *const Ui) bool {
        if (self.snapshot.update_queue) |saved| if (saved.value.current()) |index|
            return saved.value.items[index].status == .pending_restart;
        return self.snapshot.pending_restart;
    }
    fn row(self: *const Ui) ?*const v.Row {
        const p = self.projection() orelse return null;
        const i = self.selected orelse return null;
        return if (i < p.rows.len) &p.rows[i] else null;
    }
    fn package(self: *const Ui) ?m.Package {
        const item = self.row() orelse return null;
        const pi = item.package_index orelse return null;
        const snapshot = self.snapshot.result.snapshot orelse return null;
        return if (pi < snapshot.catalog.packages.len) snapshot.catalog.packages[pi] else null;
    }
    fn category(self: *const Ui) ?[]const u8 {
        const p = self.projection() orelse return null;
        return if (self.category_index > 0 and self.category_index <= p.categories.len) p.categories[self.category_index - 1] else null;
    }
    fn isVisible(self: *const Ui, item: v.Row) bool {
        return item.visible(self.tab, self.kind, self.category(), self.search.value());
    }
    fn custom(self: *const Ui, id: []const u8) ?*const r.AbsoluteFilePath {
        for (self.customs.items) |*item| if (std.mem.eql(u8, item.id, id)) return &item.destination;
        return null;
    }
    fn destination(self: *const Ui, item: v.Row) ?[]const u8 {
        if (item.actual_path) |actual| return actual;
        if (self.custom(item.package_id)) |path| return path.bytes();
        return item.proposed_path;
    }
    fn typeRects(self: *const Ui, canvas: g.Canvas) [3]g.Rect {
        var result: [3]g.Rect = undefined;
        var x: i32 = 24;
        for (kinds, 0..) |name, i| {
            const width = @max(84, canvas.textWidthZ(name.ptr) + self.style.padding * 2 + 4);
            result[i] = .{ .x = x, .y = 112, .w = width, .h = 34 };
            x += width + 8;
        }
        return result;
    }
    fn searchRect(self: *const Ui, canvas: g.Canvas) g.Rect {
        const width = @min(320, canvas.w - self.typeRects(canvas)[2].right() - 40);
        return .{ .x = canvas.w - width - 24, .y = 112, .w = width, .h = 34 };
    }
    fn modal(_: *const Ui, canvas: g.Canvas) g.ModalDialog {
        return g.ModalDialog.centered(canvas.bounds(), @min(720, canvas.w - 32), @min(456, canvas.h - 32), "Paketdetails");
    }
    fn allowed(self: *const Ui, action: jobs.Action, item: ?v.Row) bool {
        const p = self.projection() orelse return false;
        if (self.pendingRemoval()) return false;
        if (self.snapshot.update_queue) |saved| if (!saved.value.completed()) return false;
        if (self.snapshot.pending_installation) return false;
        if (action == .uninstall) return self.capabilities.uninstall and !self.busy and p.inventory_known and
            item != null and item.?.package_id.len != 0 and item.?.kind == .application and item.?.observed and item.?.actual_path != null and
            item.?.installed_version != null and item.?.status != .conflict and item.?.status != .unverified;
        const installed = if (item) |i| i.status == .installed or i.status == .update else false;
        const newer = if (item) |i| i.status == .update else blk: {
            for (p.rows) |row_value| if (row_value.status == .update) break :blk true;
            break :blk false;
        };
        if (action == .install and (item == null or item.?.status != .available)) return false;
        return self.capabilities.allows(action, p.fresh and p.inventory_known and self.snapshot.failure == null, self.busy, installed, if (item) |i| i.kind == .application else false, newer);
    }
    fn featured(self: *const Ui, p: *const v.Projection) ?usize {
        if (self.tab != .discover or self.kind != .application or self.search.value().len != 0) return null;
        for (p.rows, 0..) |item, i| if (self.isVisible(item) and item.package_index != null and item.status != .unavailable) return i;
        return null;
    }
    fn hero(self: *Ui, canvas: g.Canvas, rect: g.Rect, index: usize, item: v.Row) bool {
        var bytes: [256]u8 = undefined;
        const stops = [_]r.gui_shapes.GradientStop{ .{ .position = 0, .argb = 0xff341f4a }, .{ .position = 0.72, .argb = 0xff341f4a }, .{ .position = 1, .argb = 0xff7950d0 } };
        const shape = r.gui_shapes.RoundedRect{ .x = 0, .y = 0, .w = @floatFromInt(rect.w), .h = @floatFromInt(rect.h), .radii = .{ .top_left_x = 12, .top_left_y = 12, .top_right_x = 12, .top_right_y = 12, .bottom_left_x = 12, .bottom_left_y = 12, .bottom_right_x = 12, .bottom_right_y = 12 } };
        const payload = r.gui_shapes.gradientRoundedRect(&bytes, shape, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = @floatFromInt(rect.w), .y = 0 }, .stops = &stops }) catch return false;
        const command = r.gui_shapes.command(r.abi.gui_frame_command_kind_gradient_rounded_rect, rect.x, rect.y, @intCast(rect.w), @intCast(rect.h), 0, payload.len) catch return false;
        if (canvas.frameCommand(command, payload) < 0) return false;
        if (!self.label(canvas.withTextRole(.caption), .{ .x = rect.x + 20, .y = rect.y + 12, .w = rect.w - 200, .h = 22 }, "Vorgestellt", 0xd8c5f8, 0x341f4a)) return false;
        if (!self.label(canvas.withTextRole(.heading), .{ .x = rect.x + 20, .y = rect.y + 38, .w = rect.w - 200, .h = 34 }, item.name, 0xf7f0ff, 0x341f4a)) return false;
        if (!self.label(canvas, .{ .x = rect.x + 20, .y = rect.y + 78, .w = rect.w - 200, .h = 24 }, item.category, 0xd8c5f8, 0x341f4a)) return false;
        return self.button(canvas, .{ .row = index }, .{ .x = rect.right() - 154, .y = rect.y + 44, .w = 130, .h = 36 }, "Details", true, false, self.focus.index == 4 and self.selected == index);
    }
    pub fn paint(self: *Ui) bool {
        var painting = switch (self.window.beginPaint()) {
            .paint => |value| value,
            .failure => return false,
        };
        defer painting.discard();
        var commands: [256]r.abi.GuiFrameCommand = undefined;
        var resources: [32768]u8 = undefined;
        var builder: r.app_gui.FrameCanvas = undefined;
        const canvas = painting.bufferedCanvas(&builder, &commands, &resources).withStyle(self.style);
        self.hit_count = 0;
        if (canvas.clear(self.style.background) < 0) return false;
        if (!self.label(canvas.withTextRole(.heading), .{ .x = 24, .y = 14, .w = 230, .h = 38 }, "Portex", self.style.text, self.style.background)) return false;
        if (!self.button(canvas, if (self.busy) .cancel else .refresh, .{ .x = canvas.w - 190, .y = 18, .w = 166, .h = 34 }, if (self.busy) "Abbrechen" else "Neu laden", true, false, self.focus.index == 5)) return false;
        if ((self.snapshot.pending_installation or self.pendingUpdates() or self.pendingRemoval()) and !self.busy and !self.button(canvas, .resume_install, .{ .x = canvas.w - 428, .y = 18, .w = 226, .h = 34 }, if (self.restartReady()) "Neustart starten" else "Wiederaufnehmen", true, true, false)) return false;
        var scratch: [1024]u8 = undefined;
        const navigation = canvas.layoutTabs(.{ .rect = .{ .x = 22, .y = 60, .w = canvas.w - 44, .h = 34 }, .items = &tabs, .selected_index = @intFromEnum(self.tab), .focused = self.active and self.focus.index == 0 });
        if (navigation.draw(canvas, &scratch) < 0) return false;
        for (0..3) |i| if (!self.hit(.{ .tab = i }, navigation.tabRect(i), true)) return false;
        const type_rects = self.typeRects(canvas);
        for (kinds, 0..) |name, i| if (!self.button(canvas, .{ .kind = i }, type_rects[i], name, true, i == @intFromEnum(self.kind), self.focus.index == 1 and i == @intFromEnum(self.kind))) return false;
        self.search.focused = self.active and self.focus.index == 2 and !self.detail;
        if (self.search.draw(canvas, self.searchRect(canvas), &scratch) < 0 or !self.hit(.search, self.searchRect(canvas), true)) return false;
        if (self.search.value().len == 0 and !self.search.focused and !self.label(canvas, self.searchRect(canvas).inset(8, 4), "Suchen...", self.style.muted, self.style.surface)) return false;
        if (!self.button(canvas, .category_toggle, .{ .x = 24, .y = 158, .w = 260, .h = 32 }, self.category() orelse "Alle Kategorien", self.projection() != null, false, self.focus.index == 3)) return false;
        if (self.tab == .updates and !self.button(canvas, .update_all, .{ .x = canvas.w - 264, .y = 158, .w = 240, .h = 32 }, "Alle aktualisieren", self.allowed(.update_all, null), true, false)) return false;
        if (!self.paintRows(canvas)) return false;
        if (!self.button(canvas, .previous, .{ .x = canvas.w - 132, .y = canvas.h - 78, .w = 48, .h = 30 }, "<", self.first > 0, false, false) or !self.button(canvas, .next, .{ .x = canvas.w - 72, .y = canvas.h - 78, .w = 48, .h = 30 }, ">", self.first + self.page_size < self.visible_count, false, false)) return false;
        var status: [768]u8 = undefined;
        const text = if (self.remove_progress) |progress| progress.describe(&status) else if (self.pendingRemoval()) "Entfernung ausstehend: App schliessen und Wiederaufnehmen" else if (self.update_progress) |progress| progress.describe(&status) else if (self.installation_progress) |progress| progress.describe(&status) else if (self.download_progress) |progress| progress.describe(&status) else if (self.busy) "Katalog wird geladen; die Ansicht bleibt bedienbar." else if (self.snapshot.failure) |err| std.fmt.bufPrint(&status, "Bestand konnte nicht vollstaendig gelesen werden: {s}", .{@errorName(err)}) catch "Bestand unbekannt" else catalog.describe(&self.snapshot.result, &status);
        if (self.snapshot.update_queue != null and !self.busy and self.download_progress == null and !self.pendingRemoval())
            if (!self.button(canvas, .queue_details, .{ .x = 24, .y = canvas.h - 78, .w = 200, .h = 30 }, "Updateauftrag", true, false, false)) return false;
        if (self.download_progress) |progress| {
            var counts: [256]u8 = undefined;
            if (!self.label(canvas.withTextRole(.caption), .{ .x = 24, .y = canvas.h - 76, .w = canvas.w - 180, .h = 24 }, progress.counts(&counts), self.style.text, self.style.background)) return false;
        }
        if (self.update_progress) |progress| if (progress.transfer_active.load(.acquire)) {
            var counts: [256]u8 = undefined;
            if (!self.label(canvas.withTextRole(.caption), .{ .x = 24, .y = canvas.h - 76, .w = canvas.w - 180, .h = 24 }, progress.counts(&counts), self.style.text, self.style.background)) return false;
        };
        var stale_text: [1024]u8 = undefined;
        const status_text = if (self.projection() != null and !self.projection().?.fresh and !self.busy) std.fmt.bufPrint(&stale_text, "Veralteter Katalog | {s}", .{text}) catch text else text;
        if (!self.label(canvas.withTextRole(.caption), .{ .x = 24, .y = canvas.h - 36, .w = canvas.w - 48, .h = 24 }, status_text, self.style.muted, self.style.background)) return false;
        if (self.category_open and !self.detail) if (self.projection()) |p| {
            const total = p.categories.len + 1;
            const count = @min(6, total - @min(self.category_first, total));
            for (0..count) |n| {
                const i = self.category_first + n;
                if (!self.button(canvas, .{ .category = i }, .{ .x = 24, .y = 192 + @as(i32, @intCast(n)) * 32, .w = 260, .h = 32 }, if (i == 0) "Alle Kategorien" else p.categories[i - 1], true, i == self.category_index, self.focus.index == 3 and i == self.category_index)) return false;
            }
        };
        if (self.detail and !self.paintDetail(canvas)) return false;
        if (self.showing_queue and !self.paintQueue(canvas)) return false;
        if (self.pendingRemoval() and !self.busy and !self.detail and !self.button(canvas, .remove_abort, .{ .x = 24, .y = canvas.h - 78, .w = 288, .h = 30 }, "Entfernung abbrechen", true, false, false)) return false;
        return painting.present() >= 0;
    }
    fn paintRows(self: *Ui, canvas: g.Canvas) bool {
        self.visible_count = 0;
        const p = self.projection() orelse return self.label(canvas, .{ .x = 24, .y = 220, .w = canvas.w - 48, .h = 32 }, if (self.busy) "Katalog und Bestand werden geladen..." else "Kein Katalog verfuegbar", self.style.muted, self.style.background);
        const featured_index = self.featured(p);
        const list_y: i32 = if (featured_index != null) 350 else 210;
        if (featured_index) |i| if (!self.hero(canvas, .{ .x = 24, .y = 210, .w = canvas.w - 48, .h = 124 }, i, p.rows[i])) return false;
        const columns: usize = if (canvas.w >= 1000) 2 else 1;
        const available_height = @max(88, canvas.h - list_y - 88);
        const rows: usize = @intCast(@max(1, @divTrunc(available_height + 12, 100)));
        self.page_size = @min(rows * columns, 16);
        const grid = g.TileGrid{ .rect = .{ .x = 24, .y = list_y, .w = canvas.w - 48, .h = available_height }, .min_width = if (columns == 2) @divTrunc(canvas.w - 60, 2) else canvas.w - 48, .gap = 12, .row_height = 88, .count = self.page_size };
        var scratch: [1024]u8 = undefined;
        for (p.rows, 0..) |item, i| {
            if (!self.isVisible(item) or featured_index == i) continue;
            const position = self.visible_count;
            self.visible_count += 1;
            if (position < self.first or position >= self.first + self.page_size) continue;
            const rect = grid.itemRect(position - self.first);
            const action = Action{ .row = i };
            var text: [512]u8 = undefined;
            const subtitle = std.fmt.bufPrint(&text, "{s} | {s}{s}", .{ item.category, item.statusText(), if (!p.fresh and item.package_index != null) " (Cache)" else "" }) catch return false;
            const card = g.Card{ .rect = rect, .title = item.name, .subtitle = subtitle, .state = if (same(self.pressed, action)) .pressed else if (same(self.hover, action)) .hover else .normal, .selected = self.selected == i, .focused = self.active and self.focus.index == 4 and self.selected == i, .icon_width = 36 };
            if (card.draw(canvas, &scratch) < 0 or !self.hit(action, rect, true)) return false;
            const icon = card.iconRect(self.style);
            if (canvas.surface(icon, .selected) < 0 or !self.label(canvas, icon, if (item.kind) |kind| switch (kind) {
                .application => "A",
                .library => "L",
                .kernel => "K",
            } else "?", self.style.accent, self.style.tint)) return false;
        }
        if (self.visible_count == 0 and featured_index == null and !self.label(canvas, .{ .x = 24, .y = 220, .w = canvas.w - 48, .h = 32 }, "Keine passenden Pakete", self.style.muted, self.style.background)) return false;
        if (self.first >= self.visible_count and self.first > 0) {
            self.first = 0;
            self.dirty = true;
        }
        return true;
    }
    fn paintQueue(self: *Ui, canvas: g.Canvas) bool {
        const saved = self.snapshot.update_queue orelse return false;
        const queue = saved.value;
        const dialog = g.ModalDialog.centered(canvas.bounds(), @min(720, canvas.w - 32), @min(456, canvas.h - 32), "Updateauftrag");
        var scratch: [2048]u8 = undefined;
        if (dialog.drawFrame(canvas, &scratch) < 0) return false;
        self.hit_count = 0;
        const box = dialog.contentRect();
        var text: [1024]u8 = undefined;
        const heading = std.fmt.bufPrint(&text, "{d}/{d} installiert | {d} ausstehend", .{ queue.installedCount(), queue.items.len, queue.items.len - queue.installedCount() }) catch return false;
        if (!self.label(canvas, .{ .x = box.x, .y = box.y, .w = box.w, .h = 26 }, heading, self.style.text, self.style.surface)) return false;
        const first = @min(self.queue_first, queue.items.len);
        const count = @min(@as(usize, 4), queue.items.len - first);
        for (queue.items[first..][0..count], 0..) |item, n| {
            const phase = switch (item.status) {
                .queued => "Wartet",
                .working => "In Bearbeitung",
                .pending_restart => "Neustart erforderlich",
                .installed => "Installiert",
                .failed => "Fehlgeschlagen",
                .cancelled => "Abgebrochen",
            };
            const line = std.fmt.bufPrint(&text, "{d}. {s} {s}: {s}", .{ first + n + 1, item.frozen.selection.title, item.frozen.selection.plan.version, phase }) catch return false;
            const y = box.y + 42 + @as(i32, @intCast(n)) * 70;
            if (!self.label(canvas, .{ .x = box.x, .y = y, .w = box.w, .h = 28 }, line, self.style.text, self.style.surface)) return false;
            if (!self.label(canvas.withTextRole(.caption), .{ .x = box.x, .y = y + 30, .w = box.w, .h = 26 }, item.failure orelse item.frozen.selection.destination, self.style.muted, self.style.surface)) return false;
        }
        const bottom = dialog.rect.bottom() - 50;
        return self.button(canvas, .previous, .{ .x = box.x, .y = bottom, .w = 64, .h = 32 }, "<", first > 0, false, false) and
            self.button(canvas, .next, .{ .x = box.x + 72, .y = bottom, .w = 64, .h = 32 }, ">", first + count < queue.items.len, false, false) and
            self.button(canvas, .detail_close, .{ .x = dialog.rect.right() - 164, .y = bottom, .w = 140, .h = 32 }, "Schliessen", true, true, false);
    }
    fn paintDetail(self: *Ui, canvas: g.Canvas) bool {
        const item = self.row() orelse return false;
        const dialog = self.modal(canvas);
        var scratch: [2048]u8 = undefined;
        if (dialog.drawFrame(canvas, &scratch) < 0) return false;
        self.hit_count = 0; // Covered background controls cannot fire.
        const box = dialog.contentRect();
        if (self.removing) {
            var text: [1024]u8 = undefined;
            const title = std.fmt.bufPrint(&text, "{s} {s} entfernen?", .{ item.name, item.installed_version orelse "" }) catch return false;
            if (!self.label(canvas.withTextRole(.heading), .{ .x = box.x, .y = box.y, .w = box.w, .h = 40 }, title, self.style.text, self.style.surface)) return false;
            if (!self.label(canvas, .{ .x = box.x, .y = box.y + 64, .w = box.w, .h = 32 }, item.actual_path orelse "", self.style.text, self.style.surface)) return false;
            if (canvas.paragraph(.{ .rect = .{ .x = box.x, .y = box.y + 112, .w = box.w, .h = 120 }, .text = "Entfernt die App-Datei und ihren Inventareintrag. Eigene unveraenderte Desktop-Links werden entfernt. Nutzerdaten, Ordner und fremde oder geaenderte Links bleiben erhalten. Eine laufende App muss zuerst geschlossen werden.", .background = self.style.surface }, &scratch) < 0) return false;
            return self.button(canvas, .remove_cancel, .{ .x = box.x, .y = dialog.rect.bottom() - 54, .w = 180, .h = 32 }, "Abbrechen", true, false, self.focus.index == 0) and
                self.button(canvas, .remove_confirm, .{ .x = box.right() - 200, .y = dialog.rect.bottom() - 54, .w = 200, .h = 32 }, "Jetzt entfernen", self.allowed(.uninstall, item.*), false, self.focus.index == 1);
        }
        if (!self.label(canvas.withTextRole(.heading), .{ .x = box.x, .y = box.y, .w = box.w, .h = 34 }, item.name, self.style.text, self.style.surface)) return false;
        var versions: [512]u8 = undefined;
        const version_text = std.fmt.bufPrint(&versions, "Verfuegbar: {s}  |  Installiert: {s}", .{ item.available_version orelse "unbekannt", item.installed_version orelse "nicht bestaetigt" }) catch return false;
        if (!self.label(canvas, .{ .x = box.x, .y = box.y + 38, .w = box.w, .h = 24 }, version_text, self.style.muted, self.style.surface)) return false;
        const description = item.description[0..utf8Prefix(item.description, 1024)];
        if (canvas.paragraph(.{ .rect = .{ .x = box.x, .y = box.y + 68, .w = box.w, .h = 64 }, .text = description, .background = self.style.surface }, &scratch) < 0) return false;
        if (!self.label(canvas, .{ .x = box.x, .y = box.y + 136, .w = box.w, .h = 24 }, if (item.actual_path != null) "Bestehender Installationspfad" else "Installationsziel", self.style.muted, self.style.surface)) return false;
        if (self.customizing) {
            self.path_field.focused = self.active;
            const field = g.Rect{ .x = box.x, .y = box.y + 164, .w = box.w, .h = 34 };
            if (self.path_field.draw(canvas, field, &scratch) < 0 or !self.hit(.path_field, field, true)) return false;
            if (!self.label(canvas, .{ .x = box.x, .y = box.y + 204, .w = box.w, .h = 24 }, if (self.path_error) |err| pathError(err) else if (self.adopting) "Vorhandene R4X-Datei angeben; technische Identitaet wird geprueft." else if (item.kind == .application) "Ordner waehlen; Originaldateiname bleibt erhalten." else "Dateiziel mit unveraendertem Originaldateinamen.", self.style.muted, self.style.surface)) return false;
            return self.button(canvas, .path_cancel, .{ .x = dialog.rect.right() - 338, .y = dialog.rect.bottom() - 54, .w = 140, .h = 32 }, "Abbrechen", true, false, false) and self.button(canvas, .path_apply, .{ .x = dialog.rect.right() - 184, .y = dialog.rect.bottom() - 54, .w = 160, .h = 32 }, "Uebernehmen", true, true, false);
        }
        if (!self.label(canvas, .{ .x = box.x, .y = box.y + 164, .w = box.w - 150, .h = 32 }, self.destination(item.*) orelse "Bootplan erforderlich", self.style.text, self.style.surface)) return false;
        const can_customize = item.actual_path == null and item.package_index != null and item.kind != .kernel and !self.busy;
        if (!self.button(canvas, .customize, .{ .x = box.right() - 138, .y = box.y + 164, .w = 138, .h = 32 }, "Anpassen", can_customize, false, self.focus.index == 1)) return false;
        if (!self.label(canvas, .{ .x = box.x, .y = box.y + 206, .w = box.w, .h = 24 }, item.statusText(), self.style.muted, self.style.surface)) return false;
        if (item.kind != .application and !self.label(canvas, .{ .x = box.x, .y = box.y + 236, .w = box.w, .h = 24 }, "Aktivierung ueber Systemupdate; Neustart erforderlich.", self.style.muted, self.style.surface)) return false;
        const can_download = !self.busy and item.package_index != null and self.snapshot.result.snapshot != null and self.snapshot.result.snapshot.?.fresh;
        if (!self.button(canvas, .download, .{ .x = box.x, .y = box.y + 268, .w = 210, .h = 32 }, "Herunterladen", can_download, false, self.focus.index == 4)) return false;
        if (item.kind == .application and !self.button(canvas, .adopt, .{ .x = box.x + 226, .y = box.y + 268, .w = box.w - 226, .h = 32 }, "Vorhandene R4X zuordnen", can_download and !self.snapshot.pending_installation and !self.pendingRemoval() and item.status != .conflict, false, false)) return false;
        const button_y = dialog.rect.bottom() - 54;
        if (!self.button(canvas, .detail_close, .{ .x = dialog.rect.x + 24, .y = button_y, .w = 140, .h = 32 }, "Schliessen", true, false, self.focus.index == 0)) return false;
        if (item.kind == .application and !self.button(canvas, .uninstall, .{ .x = dialog.rect.right() - 388, .y = button_y, .w = 180, .h = 32 }, "Deinstallieren", self.allowed(.uninstall, item.*), false, self.focus.index == 2)) return false;
        return self.button(canvas, if (item.actual_path != null) .update else .install, .{ .x = dialog.rect.right() - 194, .y = button_y, .w = 170, .h = 32 }, if (item.actual_path != null) "Aktualisieren" else "Installieren", self.allowed(if (item.actual_path != null) .update else .install, item.*), true, self.focus.index == 3);
    }
    fn utf8Prefix(text: []const u8, limit: usize) usize {
        var end = @min(text.len, limit);
        while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
        return end;
    }
    fn pathError(err: anyerror) []const u8 {
        return switch (err) {
            error.ExpectedAbsolute => "Absoluter Pfad mit Laufwerk erforderlich.",
            error.RootTraversal => "Der Pfad verlaesst das Laufwerk.",
            error.OriginalFilenameRequired => "Der Originaldateiname muss erhalten bleiben.",
            error.TooLong, error.ComponentTooLong => "Der Zielpfad ist zu lang.",
            error.InvalidCharacter, error.EmbeddedNul => "Der Pfad enthaelt ungueltige Zeichen.",
            error.Empty, error.MissingDestination => "Bitte einen Zielpfad angeben.",
            error.OutOfMemory => "Nicht genug Speicher fuer den Zielpfad.",
            else => "Der Zielpfad konnte nicht uebernommen werden.",
        };
    }
    fn execute(self: *Ui, action: Action) void {
        switch (action) {
            .tab => |n| {
                self.tab = @enumFromInt(n);
                self.first = 0;
                self.focus.index = 0;
            },
            .kind => |n| {
                self.kind = @enumFromInt(n);
                self.first = 0;
                self.focus.index = 1;
            },
            .search => self.focus.index = 2,
            .category_toggle => {
                self.category_open = !self.category_open;
                self.focus.index = 3;
            },
            .category => |n| {
                self.category_index = n;
                self.category_open = false;
                self.first = 0;
                self.focus.index = 3;
            },
            .refresh => {
                if (!self.busy) self.reload_requested = true;
            },
            .cancel => self.cancel_requested = true,
            .resume_install => {
                if (!self.busy) {
                    if (self.pendingRemoval()) self.remove_resume = true else if (self.restartReady()) self.restart_requested = true else self.resume_requested = true;
                }
            },
            .queue_details => {
                self.showing_queue = true;
                self.queue_first = 0;
                self.detail = false;
            },
            .adopt => {
                const item = self.row() orelse return;
                if (self.busy or item.package_index == null or item.kind != .application) return;
                if (!self.path_field.setExact(self.destination(item.*) orelse "C:\\")) return;
                self.adopting = true;
                self.customizing = true;
                self.path_error = null;
            },
            .download => {
                const item = self.row() orelse return;
                if (self.busy or item.package_index == null or self.snapshot.result.snapshot == null or !self.snapshot.result.snapshot.?.fresh) return;
                self.download_requested = item.package_index;
                self.detail = false;
                self.customizing = false;
                self.category_open = false;
                self.focus.index = 5;
            },
            .previous => if (self.showing_queue) {
                self.queue_first -|= 4;
            } else {
                self.first -|= self.page_size;
            },
            .next => if (self.showing_queue) {
                if (self.snapshot.update_queue) |saved| if (self.queue_first + 4 < saved.value.items.len) {
                    self.queue_first += 4;
                };
            } else if (self.first + self.page_size < self.visible_count) {
                self.first += self.page_size;
            },
            .row => |i| {
                self.selected = i;
                self.detail = true;
                self.customizing = false;
                self.category_open = false;
                self.focus.index = 0;
            },
            .detail_close => {
                self.detail = false;
                self.showing_queue = false;
                self.customizing = false;
                self.focus.index = 4;
            },
            .customize => {
                const item = self.row() orelse return;
                const p = self.package() orelse return;
                if (item.actual_path != null or p.package_type == .kernel or self.busy) return;
                const path = self.destination(item.*) orelse return;
                const value = if (p.installation.path_kind == .directory) path[0..@max(3, std.mem.lastIndexOfScalar(u8, path, '\\') orelse return)] else path;
                if (!self.path_field.setExact(value)) return;
                self.customizing = true;
                self.adopting = false;
                self.path_error = null;
            },
            .path_field => {},
            .path_cancel => self.customizing = false,
            .path_apply => {
                const p = self.package() orelse return;
                if (self.adopting) {
                    const item = self.row() orelse return;
                    const path = r.AbsoluteFilePath.parse(self.path_field.value()) catch |err| {
                        self.path_error = err;
                        return;
                    };
                    if (item.actual_path) |actual| if (!v.samePath(path.bytes(), actual)) {
                        self.path_error = error.BindingConflict;
                        return;
                    };
                    self.install_requested = .{ .package_index = item.package_index orelse return, .destination = path, .adopt = true };
                    self.detail = false;
                    self.customizing = false;
                    self.focus.index = 5;
                    return;
                }
                const destination_value = v.resolveNew(p, self.path_field.value()) catch |err| {
                    self.path_error = err;
                    self.dirty = true;
                    return;
                };
                for (self.customs.items) |*item| if (std.mem.eql(u8, item.id, p.package_id)) {
                    item.destination = destination_value;
                    self.customizing = false;
                    self.dirty = true;
                    return;
                };
                const id = self.allocator.dupe(u8, p.package_id) catch {
                    self.path_error = error.OutOfMemory;
                    return;
                };
                self.customs.append(self.allocator, .{ .id = id, .destination = destination_value }) catch {
                    self.allocator.free(id);
                    self.path_error = error.OutOfMemory;
                    return;
                };
                self.customizing = false;
            },
            // Only implemented owner adapters may enable/publish mutations.
            .install, .update => {
                const item = self.row() orelse return;
                const updating = std.meta.activeTag(action) == .update;
                if (!self.allowed(if (updating) .update else .install, item.*)) return;
                const path: ?r.AbsoluteFilePath = if (item.kind == .kernel) null else r.AbsoluteFilePath.parse(self.destination(item.*) orelse return) catch return;
                self.install_requested = .{ .package_index = item.package_index orelse return, .destination = path, .replace = updating };
                self.detail = false;
                self.customizing = false;
                self.focus.index = 5;
            },
            .update_all => {
                if (self.allowed(.update_all, null)) self.update_all_requested = true;
            },
            .uninstall => {
                const item = self.row() orelse return;
                if (!self.allowed(.uninstall, item.*)) return;
                self.removing = true;
                self.focus.index = 0;
            },
            .remove_cancel => self.removing = false,
            .remove_confirm => {
                const item = self.row() orelse return;
                if (!self.removing or !self.allowed(.uninstall, item.*)) return;
                self.remove_requested = self.selected;
                self.removing = false;
                self.detail = false;
            },
            .remove_abort => {
                self.remove_resume = true;
                self.remove_abort = true;
            },
        }
        self.dirty = true;
    }
    pub fn key(self: *Ui, message: r.app_gui.KeyMessage) void {
        // The desktop admits CR and LF as Enter. Editing consumes the
        // original Unicode codepoint; command navigation uses one key value.
        const key_value = navigationKey(message);
        if (self.removing) {
            if (key_value == g.Key.escape) self.execute(.remove_cancel) else if (key_value == g.Key.tab or key_value == g.Key.shift_tab) {
                self.focus.index = (self.focus.index + 1) % 2;
                self.dirty = true;
            } else if (key_value == g.Key.enter or key_value == ' ') self.execute(if (self.focus.index == 1) .remove_confirm else .remove_cancel);
            return;
        }
        if (self.showing_queue) {
            if (key_value == g.Key.escape or key_value == g.Key.enter) self.execute(.detail_close) else if (key_value == g.Key.left) self.execute(.previous) else if (key_value == g.Key.right) self.execute(.next);
            return;
        }
        if (self.customizing) {
            if (key_value == g.Key.escape) self.customizing = false else if (key_value == g.Key.enter) self.execute(.path_apply) else _ = self.path_field.handleClipboardCodepoint(&self.window.desk, if (message.codepoint == 0) key_value else message.codepoint);
            self.dirty = true;
            return;
        }
        if (self.detail) {
            if (key_value == g.Key.escape) self.execute(.detail_close) else if (key_value == g.Key.tab or key_value == g.Key.shift_tab) self.focus.index = (self.focus.index + if (key_value == g.Key.tab) @as(usize, 1) else 4) % 5 else if (key_value == g.Key.enter or key_value == ' ') {
                if (self.focus.index == 0) self.execute(.detail_close) else if (self.focus.index == 1) self.execute(.customize) else if (self.focus.index == 4) self.execute(.download);
            }
            self.dirty = true;
            return;
        }
        if (key_value == g.Key.tab or key_value == g.Key.shift_tab) {
            self.category_open = false;
            _ = self.focus.handleKey(&focus_items, key_value);
            if (self.focus.index == 4 and self.selected == null) self.selectNext(true);
        } else switch (self.focus.index) {
            0 => {
                const step = self.layoutCanvas().layoutTabs(.{ .rect = .{}, .items = &tabs, .selected_index = @intFromEnum(self.tab) }).keyAction(key_value);
                self.tab = @enumFromInt(step.index);
                self.first = 0;
            },
            1 => if (key_value == g.Key.left or key_value == g.Key.right) {
                self.kind = @enumFromInt((@intFromEnum(self.kind) + @as(usize, if (key_value == g.Key.right) 1 else 2)) % 3);
                self.first = 0;
            },
            2 => {
                _ = self.search.handleClipboardCodepoint(&self.window.desk, if (message.codepoint == 0) key_value else message.codepoint);
                self.first = 0;
            },
            3 => if (self.projection()) |p| {
                if (key_value == g.Key.escape) self.category_open = false else if (key_value == g.Key.enter or key_value == ' ') self.category_open = !self.category_open else if (key_value == g.Key.down or key_value == g.Key.up) {
                    self.category_index = if (key_value == g.Key.down) @min(p.categories.len, self.category_index + 1) else self.category_index -| 1;
                    self.category_first = if (self.category_index >= 6) self.category_index - 5 else 0;
                    self.first = 0;
                }
            },
            4 => if (key_value == g.Key.enter) {
                if (self.selected) |i| self.execute(.{ .row = i });
            } else if (key_value == g.Key.down or key_value == g.Key.up) self.selectNext(key_value == g.Key.down),
            5 => if (key_value == g.Key.enter or key_value == ' ') self.execute(if (self.busy) .cancel else .refresh),
            else => {},
        }
        self.dirty = true;
    }
    fn selectNext(self: *Ui, forward: bool) void {
        const p = self.projection() orelse return;
        var candidate: ?usize = null;
        for (p.rows, 0..) |item, i| if (self.isVisible(item)) {
            if (self.selected == null) {
                candidate = i;
                break;
            }
            if (forward and i > self.selected.?) {
                candidate = i;
                break;
            }
            if (!forward and i < self.selected.?) candidate = i;
        };
        if (candidate) |i| {
            self.selected = i;
            self.first = 0;
            var position: usize = 0;
            const feature = self.featured(p);
            for (p.rows[0..i], 0..) |item, n| if (self.isVisible(item) and feature != n) {
                position += 1;
            };
            if (position >= self.page_size) self.first = position / self.page_size * self.page_size;
        }
    }
    fn layoutCanvas(self: *Ui) g.Canvas {
        var info: r.abi.GuiWindowInfo = .{};
        _ = self.window.desk.guiWindowInfo(&info);
        return g.Canvas.init(&self.window.draw, info).withStyle(self.style);
    }
    pub fn mouse(self: *Ui, message: r.app_gui.MouseMessage) void {
        const action = self.at(message.x, message.y);
        switch (message.action) {
            .move => self.hover = action,
            .down => {
                if ((message.buttons & 1) == 0) return;
                if (self.category_open) {
                    const tag = if (action) |value| std.meta.activeTag(value) else null;
                    if (tag != .category and tag != .category_toggle) self.category_open = false;
                }
                if (action) |value| {
                    if (std.meta.activeTag(value) == .search) {
                        self.focus.index = 2;
                        self.search.cursor = self.layoutCanvas().textIndexAt(self.search.value(), message.x - self.searchRect(self.layoutCanvas()).x - g.default_metrics.text_pad_x);
                        self.search.clearSelection();
                    }
                    if (std.meta.activeTag(value) == .path_field) {
                        const box = self.modal(self.layoutCanvas()).contentRect();
                        self.path_field.cursor = self.layoutCanvas().textIndexAt(self.path_field.value(), message.x - box.x - g.default_metrics.text_pad_x);
                        self.path_field.clearSelection();
                    }
                    if (self.acquire()) {
                        self.pressed = value;
                        self.capture.begin(0, .submitted);
                    }
                }
            },
            .up => {
                const pending = self.pressed;
                const matches = if (pending) |value| same(action, value) else false;
                const event = self.capture.release(0, matches);
                self.release();
                if (event == .submitted) if (pending) |value| self.execute(value);
            },
        }
        self.dirty = true;
    }
    pub fn replaced(self: *Ui, next: *const load.Snapshot) void {
        const old_category = self.category();
        var next_category: usize = 0;
        if (old_category) |name| if (next.projection) |projection_value| {
            for (projection_value.categories, 0..) |category_name, i| if (std.mem.eql(u8, name, category_name)) {
                next_category = i + 1;
                break;
            };
        };
        self.release();
        self.detail = false;
        self.customizing = false;
        self.selected = null;
        self.first = 0;
        self.category_index = next_category;
        self.showing_queue = false;
        self.category_first = 0;
        self.category_open = false;
        self.dirty = true;
    }
    pub fn wheel(self: *Ui, delta: i32) void {
        if (self.showing_queue) {
            self.execute(if (delta < 0) .next else .previous);
            return;
        }
        if (self.detail) return;
        if (self.category_open) {
            const p = self.projection() orelse return;
            self.category_first = if (delta < 0) @min((p.categories.len + 1) -| 6, self.category_first + 1) else self.category_first -| 1;
        } else if (delta < 0) {
            if (self.first + self.page_size < self.visible_count) self.first += self.page_size;
        } else self.first -|= self.page_size;
        self.dirty = true;
    }
};
