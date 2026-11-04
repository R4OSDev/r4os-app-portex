const std = @import("std");
const r4os = @import("r4os");
const model = @import("model.zig");
const state = @import("state.zig");
const catalog = @import("catalog_client.zig");

const CatalogJob = struct {
    app: *r4os.App,
    allocator: std.mem.Allocator,
    stop: r4os.app_contract.StopFlag = .{},
    result: catalog.Result = .{},

    fn entry(context: u64) callconv(.c) i32 {
        const self: *CatalogJob = @ptrFromInt(context);
        self.result = catalog.refresh(self.app, self.allocator, &self.stop);
        return 0;
    }
};

fn paint(window: *r4os.Window, status: [*:0]const u8) i32 {
    var p = switch (window.beginPaint()) {
        .paint => |v| v,
        .failure => |n| return n,
    };
    defer p.discard();
    _ = p.canvas.clear(0x19151E);
    _ = p.canvas.text(24, 24, "Portex", 0xF7F0FF, 0x19151E);
    _ = p.canvas.text(24, 58, "Software fuer R4OS", 0xB6A8C6, 0x19151E);
    _ = p.canvas.text(24, 100, status, 0xB6A8C6, 0x19151E);
    return p.present();
}

pub fn r4_app_main(app: *r4os.App) i32 {
    // Keep the same typed catalog/bindings in the actual freestanding graph.
    _ = model.Catalog;
    const sys = app.system();
    const files = app.files() orelse return -5;
    const bindings = state.load(&files, sys.allocator(), state.default_path) catch {
        sys.println("Portex: gespeicherte Paketzuordnung konnte nicht gelesen werden.");
        return -6;
    };
    defer bindings.deinit();
    var timers: [1]r4os.Timer = .{.{}};
    var window = r4os.Window.init(app.system(), app.desktop() orelse return -1, app.drawing() orelse return -1, &timers) orelse return -2;
    _ = window.setTitle("Portex");
    var status: [384:0]u8 = .{0} ** 384;
    const initial = "Softwarekatalog wird geladen...";
    @memcpy(status[0..initial.len], initial);
    if (paint(&window, &status) < 0) return -3;
    var job = CatalogJob{ .app = app, .allocator = sys.allocator() };
    const resources = app.resources();
    if (!resources.available()) return -7;
    var thread = switch (resources.createThread(CatalogJob.entry, @intFromPtr(&job), 256 * 1024)) {
        .handle => |handle| handle,
        .failure => return -7,
    };
    var closing = false;
    var exit_code: i32 = 0;
    const period = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(100_000_000));
    // Keep every borrowed app/job/result buffer until the native join receipt.
    while (true) {
        closing = closing or app.shouldClose();
        if (closing) job.stop.request();
        if (thread.valid()) switch (thread.join(if (closing) period else r4os.time_contract.timeoutPoll())) {
            .exited => {
                @memset(&status, 0);
                _ = catalog.describe(&job.result, &status);
                if (!closing and paint(&window, &status) < 0) {
                    closing = true;
                    exit_code = -4;
                }
            },
            .timed_out => {},
            .failure => {
                closing = true;
                exit_code = -8;
                if (thread.valid()) sys.sleepTicks(@max(1, sys.monotonicHz() / 10));
            },
        };
        if (closing and !thread.valid()) break;
        if (closing) continue;
        switch (window.waitMessage(period)) {
            .message => |message| switch (message) {
                .close => closing = true,
                .resize => if (paint(&window, &status) < 0) {
                    closing = true;
                    exit_code = -4;
                },
                else => {},
            },
            .failure => |code| {
                closing = true;
                exit_code = code;
            },
            else => {},
        }
    }
    job.result.deinit();
    return exit_code;
}
