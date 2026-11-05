const r = @import("r4os");
const load = @import("load_job.zig");
const ui = @import("ui.zig");
const download = @import("download.zig");
const installation = @import("installation.zig");
const updates = @import("update_queue.zig");
const uninstall = @import("uninstall.zig");
const r4std = @import("r4std");

pub fn r4_app_main(app: *r.App) i32 {
    if (!r4std.init(app.startContext())) return r.abi.err_no_group;
    var timers: [0]r.Timer = .{};
    var window = r.Window.init(app.system(), app.desktop() orelse return -1, app.drawing() orelse return -1, &timers) orelse return -2;
    _ = window.setTitle("Portex");
    _ = window.setMinimumSize(680, 560);
    var snapshot: load.Snapshot = .{};
    defer snapshot.deinit();
    var view = ui.Ui{ .window = &window, .allocator = app.system().allocator(), .snapshot = &snapshot, .style = r.gui.Style.light().withSystemFonts(&window.draw), .reload_requested = true, .capabilities = .{ .install = true, .update = true, .update_all = true, .uninstall = true } };
    defer view.deinit();
    const focus_client = r.desktop_actions.Client{ .sys = window.sys };
    switch (focus_client.focusSnapshot(.{ .window_id = @intCast(window.id) })) {
        .reply => |reply| if (reply.result == 0) {
            view.active = reply.snapshot.focus_state == r.abi.desktop_focus_state_focused;
        },
        .failure => {},
    }
    var job = load.Job{ .app = app, .allocator = app.system().allocator() };
    var download_job: download.Job = undefined;
    var install_job: installation.Job = undefined;
    var update_job: updates.Job = undefined;
    var remove_job: uninstall.Job = undefined;
    var selection: ?[]updates.Selection = null;
    defer if (selection) |items| app.system().allocator().free(items);
    var mode: enum { load, download, install, update, remove } = .load;
    var thread: ?r.app_resources.JoinHandle = null;
    const resources = app.resources();
    var closing = false;
    var exit_code: i32 = 0;
    var next_progress_paint: u64 = 0;
    var next_refresh: u64 = 0;
    const period = r.time_contract.timeoutFinite(r.time_contract.durationFromNanoseconds(100_000_000));
    while (true) {
        closing = closing or app.shouldClose();
        if (closing or view.cancel_requested) {
            switch (mode) {
                .remove => remove_job.stop.request(),
                .update => update_job.stop.request(),
                .download => download_job.stop.request(),
                .load => job.stop.request(),
                .install => {
                    install_job.stop.request();
                    if (install_job.download_job) |*dl| dl.stop.request();
                },
            }
            view.cancel_requested = false;
        }
        // Search only while Portex is open. Defer refresh while an immutable
        // snapshot is borrowed or the user is interacting with a dialog.
        if (!closing and thread == null and app.system().ticks() >= next_refresh and
            !view.detail and !view.customizing and !view.showing_queue and !view.category_open and view.remove_requested == null and !view.remove_resume)
            view.reload_requested = true;
        if (!closing and thread == null and (view.remove_requested != null or view.remove_resume)) {
            const index = view.remove_requested;
            remove_job = .{ .app = app, .allocator = app.system().allocator(), .resuming = view.remove_resume, .cancel = view.remove_abort };
            if (index) |i| if (snapshot.projection) |*projection| if (i < projection.rows.len) {
                const row = projection.rows[i];
                remove_job.target = row.actual_path;
                remove_job.name = row.target;
                remove_job.version = row.installed_version orelse "";
                remove_job.package_id = row.package_id;
            };
            view.remove_requested = null;
            view.remove_resume = false;
            view.remove_abort = false;
            view.download_progress = null;
            view.installation_progress = null;
            view.update_progress = null;
            view.remove_progress = &remove_job.progress;
            switch (resources.createThread(uninstall.Job.entry, @intFromPtr(&remove_job), 512 * 1024)) {
                .handle => |handle| {
                    thread = handle;
                    mode = .remove;
                    view.busy = true;
                },
                .failure => snapshot.failure = error.WorkerUnavailable,
            }
            view.dirty = true;
        }
        const queued_resume = view.pendingUpdates() and (view.resume_requested or view.restart_requested);
        const queued_new = view.update_all_requested or (view.install_requested != null and view.install_requested.?.replace);
        if (!closing and thread == null and (queued_resume or queued_new)) {
            const only = if (view.update_all_requested) null else if (view.install_requested) |request| request.package_index else null;
            const activating = view.restart_requested;
            view.update_all_requested = false;
            view.install_requested = null;
            view.resume_requested = false;
            view.restart_requested = false;
            var ready = queued_resume;
            if (!queued_resume) {
                selection = updates.select(app.system().allocator(), &snapshot, only) catch |err| blk: {
                    snapshot.failure = err;
                    break :blk null;
                };
                ready = selection != null;
            }
            if (ready) {
                view.remove_progress = null;
                const total = if (queued_resume) snapshot.update_queue.?.value.items.len else selection.?.len;
                update_job = .{ .app = app, .allocator = app.system().allocator(), .selection = selection, .activate = activating, .progress = .{ .total = total } };
                view.installation_progress = null;
                view.download_progress = null;
                view.update_progress = &update_job.progress;
                switch (resources.createThread(updates.Job.entry, @intFromPtr(&update_job), 512 * 1024)) {
                    .handle => |handle| {
                        thread = handle;
                        mode = .update;
                        view.busy = true;
                    },
                    .failure => {
                        snapshot.failure = error.WorkerUnavailable;
                        view.update_progress = null;
                        if (selection) |items| app.system().allocator().free(items);
                        selection = null;
                    },
                }
            }
            view.dirty = true;
        }
        if (!closing and (view.install_requested != null or view.resume_requested or view.restart_requested) and thread == null) {
            const request = view.install_requested;
            const resuming = view.resume_requested or view.restart_requested;
            const restarting = view.restart_requested;
            view.install_requested = null;
            view.resume_requested = false;
            view.restart_requested = false;
            var created = false;
            if (resuming) {
                install_job = .{ .app = app, .allocator = app.system().allocator(), .resuming = true, .commit_restart = restarting };
                created = true;
            } else if (request) |value| if (snapshot.result.snapshot) |*cached| if (cached.fresh and value.package_index < cached.catalog.packages.len) {
                const package = cached.catalog.packages[value.package_index];
                if (download.Plan.init(package, cached.origin, cached.profile)) |plan| {
                    install_job = .{ .app = app, .allocator = app.system().allocator(), .destination = value.destination, .title = package.display_name, .adopt = value.adopt, .replace = value.replace, .download_job = .{ .app = app, .allocator = app.system().allocator(), .plan = plan, .progress = .{ .total = plan.size } } };
                    created = true;
                } else |err| snapshot.failure = err;
            };
            if (created) {
                view.remove_progress = null;
                view.update_progress = null;
                view.installation_progress = &install_job.progress;
                view.download_progress = if (install_job.download_job) |*dl| &dl.progress else null;
                switch (resources.createThread(installation.Job.entry, @intFromPtr(&install_job), 512 * 1024)) {
                    .handle => |handle| {
                        thread = handle;
                        mode = .install;
                        view.busy = true;
                    },
                    .failure => {
                        snapshot.failure = error.WorkerUnavailable;
                        view.installation_progress = null;
                    },
                }
            }
            view.dirty = true;
        }
        if (!closing and view.download_requested != null and thread == null) {
            const index = view.download_requested.?;
            view.download_requested = null;
            if (snapshot.result.snapshot) |*cached| if (cached.fresh and index < cached.catalog.packages.len) {
                const plan = download.Plan.init(cached.catalog.packages[index], cached.origin, cached.profile);
                if (plan) |value| {
                    view.remove_progress = null;
                    // Snapshot and all plan slices remain alive through join.
                    download_job = .{ .app = app, .allocator = app.system().allocator(), .plan = value, .progress = .{ .total = value.size } };
                    view.download_progress = &download_job.progress;
                    view.update_progress = null;
                    view.installation_progress = null;
                    switch (resources.createThread(download.Job.entry, @intFromPtr(&download_job), 256 * 1024)) {
                        .handle => |handle| {
                            thread = handle;
                            mode = .download;
                            view.busy = true;
                        },
                        .failure => {
                            download_job.progress.failure(error.WorkerUnavailable);
                            download_job.progress.set(.failed);
                        },
                    }
                } else |err| {
                    snapshot.failure = err;
                }
            };
            view.dirty = true;
        }
        if (!closing and view.reload_requested and thread == null) {
            view.reload_requested = false;
            if (view.installation_progress == null) view.download_progress = null;
            job = .{ .app = app, .allocator = app.system().allocator() };
            switch (resources.createThread(load.Job.entry, @intFromPtr(&job), 256 * 1024)) {
                .handle => |handle| {
                    thread = handle;
                    mode = .load;
                    view.busy = true;
                },
                .failure => {
                    snapshot.failure = error.WorkerUnavailable;
                    view.busy = false;
                },
            }
            view.dirty = true;
        }
        if (thread) |*worker| switch (worker.join(if (closing) period else r.time_contract.timeoutPoll())) {
            .exited => {
                if (mode == .load) {
                    view.replaced(&job.output);
                    snapshot.deinit();
                    snapshot = job.output;
                    job.output = .{};
                    next_refresh = app.system().ticks() +| app.system().monotonicHz() * 300;
                }
                if (mode == .install or mode == .update or mode == .remove) view.reload_requested = true;
                if (mode == .update) {
                    if (selection) |items| app.system().allocator().free(items);
                    selection = null;
                }
                thread = null;
                view.busy = false;
                view.dirty = true;
            },
            .timed_out => {},
            .failure => {
                closing = true;
                exit_code = -8;
                app.system().sleepTicks(@max(1, app.system().monotonicHz() / 10));
            },
        };
        const now = app.system().ticks();
        if (thread != null and mode != .load and now >= next_progress_paint) {
            view.dirty = true;
            next_progress_paint = now +| @max(1, app.system().monotonicHz() / 4);
        }
        if (closing) {
            if (thread == null) break;
            continue;
        }
        if (view.dirty) {
            view.dirty = false;
            if (!view.paint()) {
                closing = true;
                exit_code = -3;
                continue;
            }
        }
        switch (window.waitMessage(period)) {
            .message => |message| switch (message) {
                .close => closing = true,
                .resize => {
                    view.release();
                    view.dirty = true;
                },
                .font_changed => {
                    view.style = view.style.withSystemFonts(&window.draw);
                    view.dirty = true;
                },
                .key => |key| view.key(key),
                .mouse => |mouse| view.mouse(mouse),
                .wheel => |wheel| view.wheel(wheel.delta),
                .focus_gained => {
                    view.active = true;
                    view.dirty = true;
                },
                .focus_lost => {
                    view.active = false;
                    view.release();
                    view.dirty = true;
                },
                .input_reset => {
                    view.release();
                    view.dirty = true;
                },
                .pointer_capture => |capture| {
                    if (capture.state == r.abi.gui_pointer_state_cancelled) view.release();
                    view.dirty = true;
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
    return exit_code;
}
