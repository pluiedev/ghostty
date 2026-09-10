//! Wrapper for handling samplers.
const vk = @import("vulkan");

const Self = @This();

/// Options for initializing a sampler.
pub const Options = struct {
    dispatch: vk.DeviceProxy,
    min_filter: vk.Filter,
    mag_filter: vk.Filter,
    wrap_s: vk.SamplerAddressMode,
    wrap_t: vk.SamplerAddressMode,
};

pub const Error = error{
    /// A Vulkan API call failed.
    VulkanFailed,
};

sampler: vk.Sampler,

/// The device dispatch needed to destroy the sampler.
dispatch: vk.DeviceProxy,

/// Initialize a sampler
pub fn init(
    opts: Options,
) Error!Self {
    const sampler = opts.dispatch.createSampler(&.{
        .mag_filter = opts.mag_filter,
        .min_filter = opts.min_filter,
        .mipmap_mode = .nearest,
        .address_mode_u = opts.wrap_s,
        .address_mode_v = opts.wrap_t,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .compare_enable = .false,
        .min_lod = 0,
        .max_lod = vk.LOD_CLAMP_NONE,
        .compare_op = .never,
        .max_anisotropy = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null) catch return error.VulkanFailed;
    errdefer opts.dispatch.destroySampler(sampler, null);

    return .{
        .sampler = sampler,
        .dispatch = opts.dispatch,
    };
}

pub fn deinit(self: Self) void {
    self.dispatch.destroySampler(self.sampler, null);
}
