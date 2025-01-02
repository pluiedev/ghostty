const std = @import("std");
const c = @import("../c.zig").c;
const wayland = @import("wayland");
const protocol = @import("../protocol.zig");
const Config = @import("../../../config.zig").Config;

const wl = wayland.client.wl;
const org = wayland.client.org;

const log = std.log.scoped(.gtk_wayland);

/// Wayland state that contains application-wide Wayland objects (e.g. wl_display).
pub const App = struct {
    display: *wl.Display,
    blur_manager: ?*org.KdeKwinBlurManager = null,

    pub fn init(common: *protocol.App) !void {
        // Check if we're actually on Wayland
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(common.gdk_display)),
            c.gdk_wayland_display_get_type(),
        ) == 0)
            return;

        var self: App = .{
            .display = @ptrCast(c.gdk_wayland_display_get_wl_display(common.gdk_display) orelse return),
        };

        log.debug("wayland platform init={}", .{self});

        const registry = try self.display.getRegistry();

        registry.setListener(*App, registryListener, &self);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        common.inner = .{ .wayland = self };
    }
};

/// Wayland state that contains Wayland objects associated with a window (e.g. wl_surface).
pub const Surface = struct {
    common: *const protocol.Surface,
    app: *App,
    surface: *wl.Surface,

    /// A token that, when present, indicates that the window is blurred.
    blur_token: ?*org.KdeKwinBlur = null,

    pub fn init(common: *protocol.Surface) void {
        const surface = c.gtk_native_get_surface(@ptrCast(common.gtk_window)) orelse return;

        // Check if we're actually on Wayland
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(surface)),
            c.gdk_wayland_surface_get_type(),
        ) == 0)
            return;

        const self: Surface = .{
            .common = common,
            .app = &common.app.inner.wayland,
            .surface = @ptrCast(c.gdk_wayland_surface_get_wl_surface(surface) orelse return),
        };

        common.inner = .{ .wayland = self };
    }

    pub fn deinit(self: Surface) void {
        if (self.blur_token) |blur| blur.release();
    }

    pub fn onConfigUpdate(self: *Surface) !void {
        try self.updateBlur();
    }

    fn updateBlur(self: *Surface) !void {
        const blur = self.common.derived_config.blur;
        log.debug("setting blur={}", .{blur});

        const mgr = self.app.blur_manager orelse {
            log.warn("can't set blur: org_kde_kwin_blur_manager protocol unavailable", .{});
            return;
        };

        if (self.blur_token) |tok| {
            // Only release token when transitioning from blurred -> not blurred
            if (!blur.enabled()) {
                mgr.unset(self.surface);
                tok.release();
                self.blur_token = null;
            }
        } else {
            // Only acquire token when transitioning from not blurred -> blurred
            if (blur.enabled()) {
                const tok = try mgr.create(self.surface);
                tok.commit();
                self.blur_token = tok;
            }
        }
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *App) void {
    switch (event) {
        .global => |global| {
            log.debug("got global interface={s}", .{global.interface});
            if (bindInterface(org.KdeKwinBlurManager, registry, global, 1)) |iface| {
                state.blur_manager = iface;
                return;
            }
        },
        .global_remove => {},
    }
}

fn bindInterface(comptime T: type, registry: *wl.Registry, global: anytype, version: u32) ?*T {
    if (std.mem.orderZ(u8, global.interface, T.interface.name) == .eq) {
        return registry.bind(global.name, T, version) catch |err| {
            log.warn("encountered error={} while binding interface {s}", .{ err, global.interface });
            return null;
        };
    } else {
        return null;
    }
}
