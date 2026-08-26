//! Thin EGL bindings via GLAD.
//!
//! Only types and functions used in Ghostty are modelled,
//! although the API design is rather flexible and can be extended
//! to add whatever is required. Drop down to `gl.egl.c` to access
//! raw EGL functions.
//!
//! Call `load()` once before using any EGL extension functions.

const std = @import("std");
pub const c = @import("c");

const log = std.log.scoped(.opengl_egl);

pub fn load() error{EglInitFailed}!void {
    if (c.gladLoadEGL() == 0) return error.EglInitFailed;
}

/// Wraps `eglGetProcAddress` for GLAD.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return c.eglGetProcAddress(name);
}

pub const Error = error{
    NotInitialized,
    BadAccess,
    BadAlloc,
    BadAttribute,
    BadContext,
    BadConfig,
    BadCurrentSurface,
    BadDisplay,
    BadSurface,
    BadMatch,
    BadParameter,
    BadNativePixmap,
    BadNativeWindow,
    ContextLost,
    Unknown,
};

pub fn getError() Error!void {
    return switch (c.eglGetError()) {
        c.EGL_SUCCESS => {},
        c.EGL_NOT_INITIALIZED => error.NotInitialized,
        c.EGL_BAD_ACCESS => error.BadAccess,
        c.EGL_BAD_ALLOC => error.BadAlloc,
        c.EGL_BAD_ATTRIBUTE => error.BadAttribute,
        c.EGL_BAD_CONTEXT => error.BadContext,
        c.EGL_BAD_CONFIG => error.BadConfig,
        c.EGL_BAD_CURRENT_SURFACE => error.BadCurrentSurface,
        c.EGL_BAD_DISPLAY => error.BadDisplay,
        c.EGL_BAD_SURFACE => error.BadSurface,
        c.EGL_BAD_MATCH => error.BadMatch,
        c.EGL_BAD_PARAMETER => error.BadParameter,
        c.EGL_BAD_NATIVE_PIXMAP => error.BadNativePixmap,
        c.EGL_BAD_NATIVE_WINDOW => error.BadNativeWindow,
        c.EGL_CONTEXT_LOST => error.ContextLost,
        else => Error.Unknown,
    };
}

pub fn mustError() Error {
    try getError();
    return error.Unknown;
}

pub fn bindApi(api: c.EGLenum) Error!void {
    if (c.eglBindAPI(api) != c.EGL_TRUE) {
        return mustError();
    }
}

pub const DeviceError = Error || error{
    /// The EGL_EXT_device_* / EGL_EXT_platform_device extensions are
    /// unavailable.
    Unsupported,
    /// No suitable device was found.
    NoDevice,
};

pub const DeviceEXT = opaque {
    pub fn queryDevicesEXT(devices: []*DeviceEXT) Error!usize {
        var num_devices: c.EGLint = 0;
        if (c.eglQueryDevicesEXT(@intCast(devices.len), @ptrCast(devices.ptr), &num_devices) == 0) {
            return mustError();
        }
        return @intCast(num_devices);
    }

    pub fn queryDeviceString(self: *DeviceEXT, name: c.EGLint) ?[*:0]const u8 {
        return c.eglQueryDeviceStringEXT(self, name);
    }
};

pub const Display = opaque {
    pub fn init(id: c.EGLNativeDisplayType) Error!*Display {
        const display = c.eglGetDisplay(id) orelse return mustError();
        return initialize(display);
    }

    pub fn initPlatformDisplay(
        platform: c.EGLenum,
        device: *anyopaque,
        attribs: ?[:c.EGL_NONE]const c.EGLAttrib,
    ) Error!*Display {
        const display = c.eglGetPlatformDisplay(
            platform,
            device,
            if (attribs) |a| a.ptr else null,
        ) orelse return mustError();
        return initialize(display);
    }

    fn initialize(display: c.EGLDisplay) Error!*Display {
        var major: c.EGLint = undefined;
        var minor: c.EGLint = undefined;
        if (c.eglInitialize(display, &major, &minor) != c.EGL_TRUE) {
            return mustError();
        }
        log.debug("EGL initialized {}.{}", .{ major, minor });
        return @ptrCast(display.?);
    }

    pub fn terminate(self: *Display) void {
        _ = c.eglTerminate(@ptrCast(self));
    }

    const StringQuery = enum(c.EGLint) {
        vendor = c.EGL_VENDOR,
        extensions = c.EGL_EXTENSIONS,
    };
    pub fn queryString(self: *Display, name: StringQuery) ?[:0]const u8 {
        return std.mem.span(c.eglQueryString(self, @intFromEnum(name)));
    }

    /// Make the EGL context current on the calling thread and (re)load
    /// the thread-local GLAD function pointers so subsequent GL work is
    /// valid. Returns an error if the context can't be made current.
    pub fn makeCurrent(self: *Display, draw: ?*Surface, read: ?*Surface, context: ?*Context) Error!void {
        if (c.eglMakeCurrent(self, draw, read, context) != c.EGL_TRUE) {
            return mustError();
        }
    }

    pub fn releaseCurrent(self: *Display) void {
        _ = c.eglMakeCurrent(self, null, null, null);
    }
};

pub const Config = opaque {
    pub fn choose(display: *Display, attrs: [:c.EGL_NONE]const c.EGLint) Error!*Config {
        var config: c.EGLConfig = undefined;
        var num_config: c.EGLint = 0;
        if (c.eglChooseConfig(
            display,
            attrs.ptr,
            &config,
            1,
            &num_config,
        ) != c.EGL_TRUE or num_config == 0) {
            return mustError();
        }
        return @ptrCast(config);
    }
};

pub const Surface = opaque {};

pub const Context = opaque {
    pub fn create(
        display: *Display,
        config: *Config,
        surface: ?*Surface,
        attrs: [:c.EGL_NONE]const c.EGLint,
    ) Error!*Context {
        const context = c.eglCreateContext(
            display,
            config,
            surface,
            attrs.ptr,
        ) orelse return mustError();
        return @ptrCast(context);
    }

    pub fn destroy(self: *Context, display: *Display) Error!void {
        if (c.eglDestroyContext(display, self) != c.EGL_TRUE) {
            return mustError();
        }
    }
};

pub fn AttribsBuilder(comptime cap: usize) type {
    return struct {
        attribs: [capacity:c.EGL_NONE]c.EGLAttrib,
        len: usize,

        const Attribs = @This();
        pub const capacity = cap;

        pub const empty: Attribs = .{
            // Save ourselves the trouble of manually terminating
            // the array with an `EGL_NONE`
            .attribs = @splat(c.EGL_NONE),
            .len = 0,
        };

        pub fn add(
            self: *Attribs,
            k: c.EGLAttrib,
            v: c.EGLAttrib,
        ) void {
            std.debug.assert(capacity - self.len >= 2);
            self.attribs[self.len] = k;
            self.attribs[self.len + 1] = v;
            self.len += 2;
        }

        pub fn items(self: *const Attribs) [:c.EGL_NONE]const c.EGLAttrib {
            return self.attribs[0..self.len :c.EGL_NONE];
        }
    };
}

/// Builds an attribute list for importing a DMA-BUF into an EGLImage.
///
/// `modifier` must not be invalid/implicit. Pass `null` instead.
pub fn dmabufImportAttribs(
    fourcc: u32,
    width: c.EGLint,
    height: c.EGLint,
    fds: []const c_int,
    strides: []const c_int,
    offsets: []const c_int,
    modifier: ?u64,
) AttribsBuilder(32) {
    // We only model four planes' worth of import attributes.
    std.debug.assert(fds.len <= 4);
    std.debug.assert(strides.len == fds.len and offsets.len == fds.len);

    var attribs: AttribsBuilder(32) = .empty;
    attribs.add(c.EGL_WIDTH, width);
    attribs.add(c.EGL_HEIGHT, height);
    attribs.add(c.EGL_LINUX_DRM_FOURCC_EXT, @intCast(fourcc));

    inline for (0..4) |i| {
        if (i < fds.len) {
            // The constants are all laid out in a systematic manner,
            // so let's use some comptime to make this easier
            const prefix = std.fmt.comptimePrint("EGL_DMA_BUF_PLANE{}_", .{i});

            attribs.add(@field(c, prefix ++ "FD_EXT"), fds[i]);
            attribs.add(@field(c, prefix ++ "OFFSET_EXT"), offsets[i]);
            attribs.add(@field(c, prefix ++ "PITCH_EXT"), strides[i]);

            if (modifier) |m| {
                const unpacked: packed struct(u64) { lo: u32, hi: u32 } = @bitCast(m);
                attribs.add(@field(c, prefix ++ "MODIFIER_LO_EXT"), unpacked.lo);
                attribs.add(@field(c, prefix ++ "MODIFIER_HI_EXT"), unpacked.hi);
            }
        }
    }
    return attribs;
}

pub const Image = opaque {
    pub fn create(
        display: *Display,
        context: ?*Context,
        target: ImageTarget,
        attrs: ?[:c.EGL_NONE]const c.EGLAttrib,
    ) Error!*Image {
        const image = c.eglCreateImage(
            display,
            context,
            @intFromEnum(target),
            target.toClientBuffer(),
            if (attrs) |a| a.ptr else null,
        ) orelse return mustError();

        return @ptrCast(image);
    }

    pub fn destroy(self: *Image, display: *Display) Error!void {
        if (c.eglDestroyImage(display, self) != c.EGL_TRUE) {
            return mustError();
        }
    }

    pub fn exportDmabufQuery(self: *Image, display: *Display) Error!DmabufQuery {
        var query: DmabufQuery = undefined;
        if (c.eglExportDMABUFImageQueryMESA(
            display,
            self,
            &query.fourcc,
            &query.num_planes,
            &query.modifier,
        ) != c.EGL_TRUE) {
            return mustError();
        }
        return query;
    }

    pub fn exportDmabuf(
        self: *Image,
        display: *Display,
        fds: []c_int,
        strides: []c_int,
        offsets: []c_int,
    ) Error!void {
        if (c.eglExportDMABUFImageMESA(
            display,
            self,
            fds.ptr,
            strides.ptr,
            offsets.ptr,
        ) != c.EGL_TRUE) {
            return mustError();
        }
    }
};

pub const ImageTarget = union(ImageTarget.Tag) {
    /// OpenGL 2D Texture with the given name.
    texture_2d: u32,

    /// DMABUF. Available with `EGL_EXT_image_dma_buf_import`.
    /// The context and buffer arguments are ignored for this target.
    linux_dma_buf,

    // Many other variants, add when needed

    pub fn toClientBuffer(self: ImageTarget) c.EGLClientBuffer {
        return switch (self) {
            // Yes this really is that cursed
            .texture_2d => |v| @ptrFromInt(@as(usize, v)),

            // Buffer is always null for DMABUFs.
            .linux_dma_buf => null,
        };
    }
};
