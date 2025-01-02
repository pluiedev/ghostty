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
    kde_blur_atom: c.Atom,

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
            .kde_blur_atom = c.gdk_x11_get_xatom_by_name_for_display(common.gdk_display, "_KDE_NET_WM_BLUR_BEHIND_REGION"),
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

    blur_region: Region,

    pub fn init(common: *protocol.Surface) void {
        const surface = c.gtk_native_get_surface(@ptrCast(common.gtk_window)) orelse return;

        // Check if we're actually on X11
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(surface)),
            c.gdk_x11_surface_get_type(),
        ) == 0)
            return;

        var blur_region: Region = .{};

        if ((comptime adwaita.versionAtLeast(0, 0, 0)) and common.derived_config.adw_enabled) {
            // NOTE(pluiedev): CSDs are a f--king mistake.
            // Please, GNOME, stop this nonsense of making a window ~30% bigger
            // internally than how they really are just for your shadows and
            // rounded corners and all that fluff. Please. I beg of you.

            var x: f64, var y: f64 = .{ 0, 0 };
            c.gtk_native_get_surface_transform(@ptrCast(common.gtk_window), &x, &y);
            blur_region.x, blur_region.y = .{ @intFromFloat(x), @intFromFloat(y) };
        }

        common.inner = .{ .x11 = .{
            .common = common,
            .app = &common.app.inner.x11,
            .window = c.gdk_x11_surface_get_xid(surface),
            .blur_region = blur_region,
        } };
    }

    pub fn onConfigUpdate(self: *Surface) !void {
        // Whether background blur is enabled could've changed. Update.
        try self.updateBlur();
    }

    pub fn onResize(self: *Surface) !void {
        // The blur region must update with window resizes
        self.blur_region.width = c.gtk_widget_get_width(@ptrCast(self.common.gtk_window));
        self.blur_region.height = c.gtk_widget_get_height(@ptrCast(self.common.gtk_window));
        try self.updateBlur();
    }

    fn updateBlur(self: *Surface) !void {
        // FIXME: This doesn't currently factor in rounded corners on Adwaita,
        // which means that the blur region will grow slightly outside of the
        // window borders. Unfortunately, actually calculating the rounded
        // region can be quite complex without having access to existing APIs
        // (cf. https://github.com/cutefishos/fishui/blob/41d4ba194063a3c7fff4675619b57e6ac0504f06/src/platforms/linux/blurhelper/windowblur.cpp#L134)
        // and I think it's not really noticable enough to justify the effort.
        // (Wayland also has this visual artifact anyway...)

        const blur = self.common.derived_config.blur;
        log.debug("set blur={}, window xid={}, region={}", .{ blur, self.window, self.blur_region });

        if (blur.enabled()) {
            _ = c.XChangeProperty(
                self.app.display,
                self.window,
                self.app.kde_blur_atom,
                c.XA_CARDINAL,
                // Despite what you might think, the "32" here does NOT mean
                // that the data should be in u32s. Instead, they should be
                // c_longs, which on any 64-bit architecture would be obviously
                // 64 bits. WTF?!
                32,
                c.PropModeReplace,
                // SAFETY: Region is an extern struct that has the same
                // representation of 4 c_longs put next to each other.
                // Therefore, reinterpretation should be safe.
                // We don't have to care about endianness either since
                // Xlib converts it to network byte order for us.
                @ptrCast(std.mem.asBytes(&self.blur_region)),
                4,
            );
        } else {
            _ = c.XDeleteProperty(self.app.display, self.window, self.app.kde_blur_atom);
        }
    }
};

const Region = extern struct {
    x: c_long = 0,
    y: c_long = 0,
    width: c_long = 0,
    height: c_long = 0,
};
