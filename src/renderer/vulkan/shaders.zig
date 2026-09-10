const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const math = @import("../../math.zig");

const vk = @import("vulkan");
const Pipeline = @import("Pipeline.zig");
const Compiled = @import("../shaders/Compiled.zig");

const log = std.log.scoped(.vulkan);

/// The entire SPIR-V shader built from shaders.slang.
const shader_data: Compiled = @import("shaders");

/// SPIR-V is a stream of 32-bit words. Copy the blob into a u32-aligned
/// constant so it can be handed to Vulkan directly. (The generated blob is
/// little-endian, as SPIR-V requires, and all supported targets are
/// little-endian.)
const shader_code align(@alignOf(u32)) = @as(
    *const [shader_data.code.spirv.len]u8,
    @ptrCast(shader_data.code.spirv.ptr),
).*;

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = "cell_text_vertex",
            .fragment_fn = "cell_text_fragment",
            .step_fn = .per_instance,
            .topology = .triangle_strip,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = "image_vertex",
            .fragment_fn = "image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = "bg_image_vertex",
            .fragment_fn = "bg_image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    topology: Pipeline.Options.PrimitiveTopology = .triangle,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription, dispatch: vk.DeviceProxy, module: vk.ShaderModule, pipeline_layout: vk.PipelineLayout) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .dispatch = dispatch,
            .pipeline_layout = pipeline_layout,
            .vertex_module = module,
            .vertex_fn = self.vertex_fn,
            .fragment_module = module,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .topology = self.topology,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// This contains the state for the shaders used by the Vulkan renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline = &.{},

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .defunct = true,
    };

    /// Initialize our shader set.
    pub fn init(
        alloc: Allocator,
        dispatch: vk.DeviceProxy,
        pipeline_layout: vk.PipelineLayout,
        post_shaders: []const []const u32,
    ) !Shaders {
        // Create the shader module shared by all our pipelines. It
        // can be destroyed once all pipelines are created since the
        // pipelines keep their own reference to the code.
        const module = dispatch.createShaderModule(&.{
            .code_size = shader_code.len,
            .p_code = @ptrCast(&shader_code),
        }, null) catch |err| {
            log.err("failed to create shader module err={}", .{err});
            return error.ShaderModuleFailed;
        };
        defer dispatch.destroyShaderModule(module, null);

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = pipeline[1].initPipeline(dispatch, module, pipeline_layout) catch |err| {
                log.err("failed to initialize pipeline {s} err={}", .{ pipeline[0], err });
                return err;
            };
            initialized_pipelines += 1;
        }

        const post_pipelines = initPostPipelines(
            alloc,
            dispatch,
            module,
            pipeline_layout,
            post_shaders,
        ) catch |err| err: {
            // If an error happens while building custom shaders we
            // want to just not use any custom shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing custom shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        // Release our custom shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// Initialize our custom shader pipelines.
fn initPostPipelines(
    alloc: Allocator,
    dispatch: vk.DeviceProxy,
    module: vk.ShaderModule,
    pipeline_layout: vk.PipelineLayout,
    shaders: []const []const u32,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |code| {
        pipelines[i] = try initPostPipeline(dispatch, module, pipeline_layout, code);
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from SPIR-V code.
fn initPostPipeline(
    dispatch: vk.DeviceProxy,
    module: vk.ShaderModule,
    pipeline_layout: vk.PipelineLayout,
    code: []const u32,
) !Pipeline {
    // Create the shader module for this custom shader's fragment
    // stage. It can be destroyed once the pipeline is created since
    // the pipeline keeps its own reference to the code.
    const post_module = dispatch.createShaderModule(&.{
        .code_size = code.len * @sizeOf(u32),
        .p_code = code.ptr,
    }, null) catch |err| {
        log.err("failed to create custom shader module err={}", .{err});
        return error.ShaderModuleFailed;
    };
    defer dispatch.destroyShaderModule(post_module, null);

    return try .init(null, .{
        .dispatch = dispatch,
        .pipeline_layout = pipeline_layout,
        // Custom shaders are really just fragment shaders so we need
        // a simple full screen vertex to render them
        .vertex_module = module,
        .vertex_fn = "full_screen_vertex",
        .fragment_module = post_module,
        // The Shadertoy prefix defines the entrypoint as `main`
        .fragment_fn = "main",
        // Custom shaders write to an opaque target,
        // so no blending is needed.
        .blending_enabled = false,
    });
}

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;

    var names: [pipeline_descs.len][]const u8 = undefined;
    var types: [pipeline_descs.len]type = @splat(Pipeline);
    var attrs: [pipeline_descs.len]StructField.Attributes = @splat(.{
        .@"align" = @alignOf(Pipeline),
    });

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    // test {
    //     // Minimizing the size of this struct is important,
    //     // so we test it in order to be aware of any changes.
    //     try std.testing.expectEqual(32, @sizeOf(CellText));
    // }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
