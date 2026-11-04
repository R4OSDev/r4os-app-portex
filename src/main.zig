const r4os = @import("r4os");
const model = @import("model.zig");
const state = @import("state.zig");

fn paint(window: *r4os.Window) i32 {
    var p = switch (window.beginPaint()) {
        .paint => |v| v,
        .failure => |n| return n,
    };
    defer p.discard();
    _ = p.canvas.clear(0x19151E);
    _ = p.canvas.text(24, 24, "Portex", 0xF7F0FF, 0x19151E);
    _ = p.canvas.text(24, 58, "Software fuer R4OS", 0xB6A8C6, 0x19151E);
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
    if (paint(&window) < 0) return -3;
    while (!app.shouldClose()) switch (window.waitMessage(r4os.time_contract.timeoutForever())) {
        .message => |message| switch (message) {
            .close => break,
            .resize => {
                if (paint(&window) < 0) return -4;
            },
            else => {},
        },
        .failure => |n| return n,
        else => {},
    };
    return 0;
}
