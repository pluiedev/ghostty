/// Utility functions for X11 handling.
const std = @import("std");
const build_options = @import("build_options");
const c = @import("../c.zig").c;
const input = @import("../../../input.zig");
const Config = @import("../../../config.zig").Config;
const protocol = @import("../protocol.zig");
const adwaita = @import("../adwaita.zig");

const log = std.log.scoped(.gtk_x11);

pub const App = struct {
    common: *protocol.App,
    display: *c.Display,

    base_event_code: c_int = 0,

    /// Initialize an Xkb struct for the given GDK display. If the display isn't
    /// backed by X then this will return null.
    pub fn init(common: *protocol.App) !void {
        // If the display isn't X11, then we don't need to do anything.
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(common.gdk_display)),
            c.gdk_x11_display_get_type(),
        ) == 0)
            return;

        var self: App = .{
            .common = common,
            .display = c.gdk_x11_display_get_xdisplay(common.gdk_display) orelse return,
        };

        log.debug("X11 platform init={}", .{self});

        // Set the X11 window class property (WM_CLASS) if are are on an X11
        // display.
        //
        // Note that we also set the program name here using g_set_prgname.
        // This is how the instance name field for WM_CLASS is derived when
        // calling gdk_x11_display_set_program_class; there does not seem to be
        // a way to set it directly. It does not look like this is being set by
        // our other app initialization routines currently, but since we're
        // currently deriving its value from x11-instance-name effectively, I
        // feel like gating it behind an X11 check is better intent.
        //
        // This makes the property show up like so when using xprop:
        //
        //     WM_CLASS(STRING) = "ghostty", "com.mitchellh.ghostty"
        //
        // Append "-debug" on both when using the debug build.

        c.g_set_prgname(common.derived_config.x11_program_name);
        c.gdk_x11_display_set_program_class(common.gdk_display, common.derived_config.app_id);

        // XKB
        log.debug("Xkb.init: initializing Xkb", .{});

        log.debug("Xkb.init: running XkbQueryExtension", .{});
        var opcode: c_int = 0;
        var base_error_code: c_int = 0;
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (c.XkbQueryExtension(
            self.display,
            &opcode,
            &self.base_event_code,
            &base_error_code,
            &major,
            &minor,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbQueryExtension", .{});
            return error.XkbInitializationError;
        }

        log.debug("Xkb.init: running XkbSelectEventDetails", .{});
        if (c.XkbSelectEventDetails(
            self.display,
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }

        common.inner = .{ .x11 = self };
    }

    /// Checks for an immediate pending XKB state update event, and returns the
    /// keyboard state based on if it finds any. This is necessary as the
    /// standard GTK X11 API (and X11 in general) does not include the current
    /// key pressed in any modifier state snapshot for that event (e.g. if the
    /// pressed key is a modifier, that is not necessarily reflected in the
    /// modifiers).
    ///
    /// Returns null if there is no event. In this case, the caller should fall
    /// back to the standard GDK modifier state (this likely means the key
    /// event did not result in a modifier change).
    pub fn modifierStateFromNotify(self: App) ?input.Mods {
        // Shoutout to Mozilla for figuring out a clean way to do this, this is
        // paraphrased from Firefox/Gecko in widget/gtk/nsGtkKeyUtils.cpp.
        if (c.XEventsQueued(self.display, c.QueuedAfterReading) == 0) return null;

        var nextEvent: c.XEvent = undefined;
        _ = c.XPeekEvent(self.display, &nextEvent);
        if (nextEvent.type != self.base_event_code) return null;

        const xkb_event: *c.XkbEvent = @ptrCast(&nextEvent);
        if (xkb_event.any.xkb_type != c.XkbStateNotify) return null;

        const xkb_state_notify_event: *c.XkbStateNotifyEvent = @ptrCast(xkb_event);
        // Check the state according to XKB masks.
        const lookup_mods = xkb_state_notify_event.lookup_mods;
        var mods: input.Mods = .{};

        log.debug("X11: found extra XkbStateNotify event w/lookup_mods: {b}", .{lookup_mods});
        if (lookup_mods & c.ShiftMask != 0) mods.shift = true;
        if (lookup_mods & c.ControlMask != 0) mods.ctrl = true;
        if (lookup_mods & c.Mod1Mask != 0) mods.alt = true;
        if (lookup_mods & c.Mod4Mask != 0) mods.super = true;
        if (lookup_mods & c.LockMask != 0) mods.caps_lock = true;

        return mods;
    }
};

pub const Surface = struct {
    common: *protocol.Surface,
    app: *App,
    window: c.Window,

    pub fn init(common: *protocol.Surface) void {
        const surface = c.gtk_native_get_surface(@ptrCast(common.gtk_window)) orelse return;

        // Check if we're actually on X11
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(surface)),
            c.gdk_x11_surface_get_type(),
        ) == 0)
            return;

        common.inner = .{ .x11 = .{
            .common = common,
            .app = &common.app.inner.x11,
            .window = c.gdk_x11_surface_get_xid(surface),
        } };
    }

    pub fn onConfigUpdate(self: *Surface) !void {
        _ = self;
    }

    pub fn onResize(self: *Surface) !void {
        _ = self;
    }

    fn updateBlur(self: *Surface) !void {
        _ = self;
    }
};
