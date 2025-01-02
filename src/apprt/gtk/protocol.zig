const std = @import("std");
const x11 = @import("protocol/x11.zig");
const wayland = @import("protocol/wayland.zig");
const c = @import("c.zig").c;
const build_options = @import("build_options");
const input = @import("../../input.zig");
const apprt = @import("../../apprt.zig");
const Config = @import("../../config.zig").Config;
const adwaita = @import("adwaita.zig");
const builtin = @import("builtin");
const key = @import("key.zig");

const log = std.log.scoped(.gtk_platform);

pub const App = struct {
    gdk_display: *c.GdkDisplay,
    derived_config: DerivedConfig,

    inner: union(enum) {
        none,
        x11: if (build_options.x11) x11.App else void,
        wayland: if (build_options.wayland) wayland.App else void,
    },

    const DerivedConfig = struct {
        app_id: [:0]const u8,
        x11_program_name: [:0]const u8,

        pub fn init(config: *const Config, app_id: [:0]const u8) DerivedConfig {
            return .{
                .app_id = app_id,
                .x11_program_name = if (config.@"x11-instance-name") |pn|
                    pn
                else if (builtin.mode == .Debug)
                    "ghostty-debug"
                else
                    "ghostty",
            };
        }
    };

    pub fn init(display: ?*c.GdkDisplay, config: *const Config, app_id: [:0]const u8) !App {
        var self: App = .{
            .inner = .none,
            .derived_config = DerivedConfig.init(config, app_id),
            .gdk_display = display orelse {
                // TODO: When does this ever happen...?
                std.debug.panic("GDK display is null!", .{});
            },
        };

        // The X11/Wayland init functions set `self.inner` when successful,
        // so we only need to keep trying if `self.inner` stays `.none`
        if (self.inner == .none and comptime build_options.wayland) try wayland.App.init(&self);
        if (self.inner == .none and comptime build_options.x11) try x11.App.init(&self);

        // Welp, no integration for you
        if (self.inner == .none) {
            log.warn(
                "neither X11 nor Wayland integrations enabled - lots of features would be missing!",
                .{},
            );
        }

        return self;
    }

    pub fn eventMods(self: *App, device: ?*c.GdkDevice, gtk_mods: c.GdkModifierType) input.Mods {
        return switch (self.inner) {
            // Add any modifier state events from Xkb if we have them (X11
            // only). Null back from the Xkb call means there was no modifier
            // event to read. This likely means that the key event did not
            // result in a modifier change and we can safely rely on the GDK
            // state.
            .x11 => |*x| if (comptime build_options.x11)
                x.modifierStateFromNotify() orelse key.translateMods(gtk_mods)
            else
                unreachable,

            // On Wayland, we have to use the GDK device because the mods sent
            // to this event do not have the modifier key applied if it was
            // pressed (i.e. left control).
            .wayland, .none => key.translateMods(c.gdk_device_get_modifier_state(device)),
        };
    }
};

pub const Surface = struct {
    app: *App,
    gtk_window: *c.GtkWindow,
    derived_config: DerivedConfig,

    inner: union(enum) {
        none,
        x11: if (build_options.x11) x11.Surface else void,
        wayland: if (build_options.wayland) wayland.Surface else void,
    },

    pub const DerivedConfig = struct {
        blur: Config.BackgroundBlur,
        adw_enabled: bool,

        pub fn init(config: *const Config) DerivedConfig {
            return .{
                .blur = config.@"background-blur-radius",
                .adw_enabled = adwaita.enabled(config),
            };
        }
    };

    pub fn init(self: *Surface, window: *c.GtkWindow, app: *App, config: *const Config) void {
        self.* = .{
            .app = app,
            .derived_config = DerivedConfig.init(config),
            .gtk_window = window,
            .inner = .none,
        };

        switch (app.inner) {
            .x11 => if (comptime build_options.x11) x11.Surface.init(self) else unreachable,
            .wayland => if (comptime build_options.wayland) wayland.Surface.init(self) else unreachable,
            .none => {},
        }
    }

    pub fn deinit(self: Surface) void {
        switch (self.inner) {
            .wayland => |wl| if (comptime build_options.wayland) wl.deinit() else unreachable,
            .x11, .none => {},
        }
    }

    pub fn onConfigUpdate(self: *Surface, config: *const Config) !void {
        self.derived_config = DerivedConfig.init(config);

        switch (self.inner) {
            .x11 => |*x| if (comptime build_options.x11) try x.onConfigUpdate() else unreachable,
            .wayland => |*wl| if (comptime build_options.wayland) try wl.onConfigUpdate() else unreachable,
            .none => {},
        }
    }

    pub fn onResize(self: *Surface) !void {
        switch (self.inner) {
            .x11 => |*x| if (comptime build_options.x11) try x.onResize() else unreachable,
            .wayland, .none => {},
        }
    }
};
