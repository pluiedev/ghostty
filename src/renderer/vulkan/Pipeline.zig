//! Wrapper for handling render pipelines.
const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const log = std.log.scoped(.vulkan);

const Self = @This();

/// The format of the render targets our pipelines render into.
///
/// Using an `*_srgb` pixel format makes Vulkan gamma encode the pixels
/// written to it *after* blending, which means we get linear alpha
/// blending rather than gamma-incorrect blending.
pub const color_format: vk.Format = .r8g8b8a8_srgb;

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// The device dispatch used to create and use the pipeline.
    dispatch: vk.DeviceProxy,

    /// The pipeline layout. All of our pipelines share a single
    /// descriptor set layout, so they also share a single pipeline
    /// layout.
    pipeline_layout: vk.PipelineLayout,

    /// The shader module containing our vertex entry point.
    vertex_module: vk.ShaderModule,
    /// Name of the vertex entry point.
    vertex_fn: [:0]const u8,

    /// The shader module containing our fragment entry point.
    fragment_module: vk.ShaderModule,
    /// Name of the fragment entry point.
    fragment_fn: [:0]const u8,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Primitive topology.
    /// The draw type of every step targeting this pipeline must match.
    topology: PrimitiveTopology = .triangle,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };

    pub const PrimitiveTopology = enum {
        triangle,
        triangle_strip,
    };
};

dispatch: vk.DeviceProxy,
pipeline: vk.Pipeline,
pipeline_layout: vk.PipelineLayout,
topology: Options.PrimitiveTopology,
stride: usize,
blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    // Set up our shader stages, referencing the entry points in the
    // shader modules.
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = opts.vertex_module,
            .p_name = opts.vertex_fn,
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = opts.fragment_module,
            .p_name = opts.fragment_fn,
        },
    };

    // Vertex input state. Our attributes are the fields of the input,
    // assigned to locations in field declaration order.
    var vis: vk.PipelineVertexInputStateCreateInfo = .{};
    var bindings: [1]vk.VertexInputBindingDescription = undefined;
    const VAT = VertexAttributes orelse struct {};
    var attributes: [@typeInfo(VAT).@"struct".fields.len]vk.VertexInputAttributeDescription = undefined;
    if (VertexAttributes) |V| {
        const input_rate: vk.VertexInputRate = switch (opts.step_fn) {
            .constant, .per_vertex => .vertex,
            .per_instance => .instance,
        };
        bindings[0] = .{
            .binding = 0,
            .stride = @sizeOf(V),
            .input_rate = input_rate,
        };

        inline for (@typeInfo(V).@"struct".fields, 0..) |field, i| {
            // Unwrap enum tags and packed struct backing integers,
            // mirroring the OpenGL renderer's attribute assignment.
            const FT = switch (@typeInfo(field.type)) {
                .@"struct" => |s| s.backing_integer.?,
                .@"enum" => |e| e.tag_type,
                else => field.type,
            };

            attributes[i] = .{
                .binding = 0,
                .location = i,
                .format = attributeFormat(FT),
                .offset = @offsetOf(V, field.name),
            };
        }

        vis.vertex_binding_description_count = 1;
        vis.p_vertex_binding_descriptions = &bindings;
        vis.vertex_attribute_description_count = attributes.len;
        vis.p_vertex_attribute_descriptions = &attributes;
    }

    const input_assembly_state: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = switch (opts.topology) {
            .triangle => .triangle_list,
            .triangle_strip => .triangle_strip,
        },
        .primitive_restart_enable = .false,
    };

    // Viewport and scissor states are set dynamically,
    // so there's no need to specify the values upfront.
    const viewport_state: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const dynamic_states = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };
    const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const rasterization_state: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const multisample_state: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    // Always use premultiplied alpha blending.
    const color_blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = if (opts.blending_enabled) .true else .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };
    const color_blend_state: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &.{color_blend_attachment},
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    // The color attachment format. With dynamic rendering this is
    // provided via the pipeline rendering create info.
    const rendering_info: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = &.{color_format},
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    const create_info: vk.GraphicsPipelineCreateInfo = .{
        .p_next = &rendering_info,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vis,
        .p_input_assembly_state = &input_assembly_state,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterization_state,
        .p_multisample_state = &multisample_state,
        .p_color_blend_state = &color_blend_state,
        .p_dynamic_state = &dynamic_state,
        .layout = opts.pipeline_layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    const create_infos = [_]vk.GraphicsPipelineCreateInfo{create_info};

    var pipelines: [1]vk.Pipeline = undefined;
    _ = try opts.dispatch.createGraphicsPipelines(
        .null_handle,
        &create_infos,
        null,
        pipelines[0..1],
    );
    const pipeline = pipelines[0];
    errdefer opts.dispatch.destroyPipeline(pipeline, null);

    return .{
        .pipeline = pipeline,
        .pipeline_layout = opts.pipeline_layout,
        .dispatch = opts.dispatch,
        .topology = opts.topology,
        .stride = if (VertexAttributes) |V| @sizeOf(V) else 0,
        .blending_enabled = opts.blending_enabled,
    };
}

pub fn deinit(self: *const Self) void {
    self.dispatch.destroyPipeline(self.pipeline, null);
}

fn attributeFormat(FT: type) vk.Format {
    return switch (FT) {
        u8 => .r8_uint,
        [2]u8 => .r8g8_uint,
        [4]u8 => .r8g8b8a8_uint,
        i8 => .r8_sint,
        u16 => .r16_uint,
        [2]u16 => .r16g16_uint,
        i16 => .r16_sint,
        [2]i16 => .r16g16_sint,
        u32 => .r32_uint,
        [2]u32 => .r32g32_uint,
        i32 => .r32_sint,
        [2]i32 => .r32g32_sint,
        [4]i32 => .r32g32b32a32_sint,
        f32 => .r32_sfloat,
        [2]f32 => .r32g32_sfloat,
        [4]f32 => .r32g32b32a32_sfloat,
        else => comptime unreachable,
    };
}
