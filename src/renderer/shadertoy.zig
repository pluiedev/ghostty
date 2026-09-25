const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const slang = @import("slang");
const configpkg = @import("../config.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.shadertoy);

/// The uniform struct used for shadertoy shaders.
pub const Uniforms = extern struct {
    resolution: [3]f32 align(16),
    time: f32 align(4),
    time_delta: f32 align(4),
    frame_rate: f32 align(4),
    frame: i32 align(4),
    channel_time: [4][4]f32 align(16),
    channel_resolution: [4][4]f32 align(16),
    mouse: [4]f32 align(16),
    date: [4]f32 align(16),
    sample_rate: f32 align(4),
    current_cursor: [4]f32 align(16),
    previous_cursor: [4]f32 align(16),
    current_cursor_color: [4]f32 align(16),
    previous_cursor_color: [4]f32 align(16),
    current_cursor_style: i32 align(4),
    previous_cursor_style: i32 align(4),
    cursor_visible: i32 align(4),
    cursor_change_time: f32 align(4),
    time_focus: f32 align(4),
    focus: i32 align(4),
    palette: [256][4]f32 align(16),
    background_color: [4]f32 align(16),
    foreground_color: [4]f32 align(16),
    cursor_color: [4]f32 align(16),
    cursor_text: [4]f32 align(16),
    selection_background_color: [4]f32 align(16),
    selection_foreground_color: [4]f32 align(16),
};

/// The target to load shaders for.
pub const Target = enum { glsl, msl };

/// A Slang session for compiling Shadertoy shaders to a single target
/// language. A session is not thread-safe and creating one isn't cheap, so
/// callers should create one and reuse it for every shader they need.
pub const Session = struct {
    global: *slang.IGlobalSession,
    session: *slang.ISession,

    pub fn init(target: Target) !Session {
        // Although creating a global session is also not cheap,
        // shader compilation should only happen on startup or
        // when configs are reloaded, so this shouldn't result in
        // a large overhead.
        const global_session = try slang.createGlobalSession(.{
            // Our *source* language is GLSL
            .enable_glsl = true,
        });
        errdefer global_session.release();

        // Slang's command-line default for GLSL-family targets is row-major
        // output, which corresponds to the "column-major" compiler option.
        const session_options = [_]slang.CompilerOptionEntry{
            .matrix_layout_column,
        };

        const target_options: []const slang.CompilerOptionEntry = switch (target) {
            .glsl => &.{},
            // Vertex buffer is hardcoded at register 0 on Metal.
            .msl => &.{slang.CompilerOptionEntry.vulkanBindShift(0, .buffer, 1)},
        };

        const target_desc: slang.TargetDesc = .{
            .format = switch (target) {
                .glsl => .glsl,
                .msl => .metal,
            },
            .compiler_option_entries = if (target_options.len > 0) target_options.ptr else null,
            .compiler_option_entry_count = @intCast(target_options.len),
        };

        const s = try global_session.createSession(.{
            .targets = &.{target_desc},
            .allow_glsl_syntax = true,
            .compiler_option_entries = &session_options,
        });

        return .{ .global = global_session, .session = s };
    }

    pub fn deinit(self: *Session) void {
        self.session.release();
        self.global.release();
    }

    /// Compile a GLSL shader into this session's target language.
    pub fn compile(
        self: *const Session,
        src: [:0]const u8,
        diags_out: ?**slang.IBlob,
    ) !*slang.IBlob {
        const module = self.session.loadModuleFromSource(
            "shadertoy",
            "shadertoy.glsl",
            src,
            diags_out,
        ) orelse return error.LoadModuleFailed;
        defer module.release();

        const entrypoint = try module.findAndCheckEntryPoint("main", .fragment, diags_out);
        defer entrypoint.release();

        const components = [_]*slang.IComponentType{ @ptrCast(module), entrypoint };
        var composite: *slang.IComponentType = undefined;
        try self.session.createCompositeComponentType(&components, &composite, diags_out);
        defer composite.release();

        const program = try composite.link(diags_out);
        defer program.release();

        var blob: *slang.IBlob = undefined;
        try program.getEntryPointCode(0, 0, &blob, diags_out);
        return blob;
    }
};

/// Load a set of shaders from files and convert them to the target
/// format. The shader order is preserved.
pub fn loadFromFiles(
    io: std.Io,
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const [:0]const u8 {
    var session: Session = try .init(target);
    defer session.deinit();

    var list: std.ArrayList([:0]const u8) = .empty;
    defer list.deinit(alloc_gpa);
    errdefer for (list.items) |shader| alloc_gpa.free(shader);

    for (paths.value.items) |item| {
        const path, const optional = switch (item) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };

        const shader = loadFromFile(
            io,
            alloc_gpa,
            path,
            &session,
            target,
        ) catch |err| {
            if (err == error.FileNotFound and optional) {
                continue;
            }

            return err;
        };
        log.info("loaded custom shader path={s}", .{path});
        try list.append(alloc_gpa, shader);
    }

    return try list.toOwnedSlice(alloc_gpa);
}

/// Load a single shader from a file and convert it to the target language
/// ready to be used with renderers.
pub fn loadFromFile(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    session: *const Session,
) ![:0]const u8 {
    // Load the shader file
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    var file_reader = file.reader(io, &.{});
    // We don't expect shaders to be large.
    var limited = file_reader.interface.limited(
        .limited(4 * 1024 * 1024),
        &.{},
    );

    // Convert the ShaderToy shader to a real GLSL shader
    const glsl = try glslFromShader(alloc, &limited.interface);

    var diags: *slang.IBlob = undefined;
    const result = session.compile(glsl, &diags) catch |err| {
        defer diags.release();
        const diags_buf = diags.getBuffer();

        if (diags_buf.len > 0) {
            log.warn("slang error path={s} info={s}", .{ path, diags_buf });
        }
        return err;
    };
    defer result.release();

    return switch (target) {
        .glsl, .msl => try alloc.dupeSentinel(u8, result.getBuffer(), 0),
        .spirv => {
            const buf = result.getBuffer();
            const aligned = try alloc.alignedAlloc(u8, .of(u32), buf.len);
            @memcpy(aligned, buf);
            return @ptrCast(aligned);
        },
    };
}

/// Convert a ShaderToy shader into valid GLSL.
///
/// ShaderToy shaders aren't full shaders, they're just implementing a
/// mainImage function and don't define any of the uniforms. This function
/// will convert the ShaderToy shader into a valid GLSL shader that can be
/// compiled and linked.
fn glslFromShader(alloc: Allocator, src: *std.Io.Reader) ![:0]u8 {
    var glsl_buf: std.Io.Writer.Allocating = .init(alloc);
    defer glsl_buf.deinit();
    const glsl_writer = &glsl_buf.writer;

    try glsl_writer.writeAll(@embedFile("shaders/shadertoy_prefix.glsl"));
    try glsl_writer.writeAll("\n\n");
    _ = try src.streamRemaining(glsl_writer);

    return try glsl_buf.toOwnedSliceSentinel(0);
}

test "shadertoy to glsl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var shader: std.Io.Reader = .fixed(test_crt);
    const src = try glslFromShader(alloc, &shader);
    defer alloc.free(src);

    var session: Session = try .init(.glsl);
    defer session.deinit();

    const glsl = try session.compile(alloc, src, null);
    defer alloc.free(glsl);

    // Sanity check that we actually compiled to GLSL.
    try testing.expect(std.mem.find(u8, glsl.getBuffer(), "#version") != null);
}

test "shadertoy to msl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var shader: std.Io.Reader = .fixed(test_crt);
    const src = try glslFromShader(alloc, &shader);
    defer alloc.free(src);

    var session = try Session.init(.msl);
    defer session.deinit();

    const msl = try session.compile(src, null);
    defer msl.release();

    // Sanity check that we actually compiled to Metal.
    try testing.expect(std.mem.find(u8, msl.getBuffer(), "metal_stdlib") != null);
}

test "shadertoy invalid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var shader: std.Io.Reader = .fixed(test_invalid);
    const src = try glslFromShader(alloc, &shader);
    defer alloc.free(src);

    var session: Session = try .init(.glsl);
    defer session.deinit();

    var diags: *slang.IBlob = undefined;

    if (session.compile(src, &diags)) |glsl| {
        glsl.release();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.LoadModuleFailed, error.Fail => {},
        else => return err,
    }
    defer diags.release();
    try testing.expect(diags.getBuffer().len > 0);
}

const test_crt = @embedFile("shaders/test_shadertoy_crt.glsl");
const test_invalid = @embedFile("shaders/test_shadertoy_invalid.glsl");
const test_focus = @embedFile("shaders/test_shadertoy_focus.glsl");
