//! The Vulkan device context.
//!
//! Unlike OpenGL, Vulkan has no implicit process-global state, so we
//! have to manage our own. This is the Vulkan equivalent of the EGL
//! display + context in the OpenGL renderer and the MTLDevice in the
//! Metal renderer. Each renderer creates its own device: sharing a
//! device between surfaces would be a worthwhile optimization but we
//! prefer simple, stateless initialization for now.
//!
//! Note that the pieces that our GPU resource types need (memory
//! allocation, one-shot uploads, dmabuf export) are exposed as value
//! types below, so that resources can hold exactly what they need
//! instead of pinning the device.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const build_config = @import("../../build_config.zig");

const vk = @import("vulkan");

const log = std.log.scoped(.vulkan);

/// Device extensions we require.
///
/// Dynamic rendering is only core in Vulkan 1.3, so we have to enable
/// it as an extension on 1.2. Luckily it is supported by the vast majority
/// of desktop Vulkan 1.2 implementations, so we shouldn't worry about
/// portability here.
const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_dynamic_rendering.name,
};

/// Device extensions we want but can work without.
///
/// Without external memory DMABUF support we fall back to CPU buffer
/// presentation, just like the OpenGL renderer does when DMABUF export fails.
///
/// Note that `VK_EXT_external_memory_dma_buf` depends on
/// `VK_KHR_external_memory_fd`, which provides the entry points used
/// to export the memory, so both are enabled together.
const optional_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_external_memory_fd.name,
    vk.extensions.ext_external_memory_dma_buf.name,
};

/// Only enable the debug validation layer in debug mode
/// since it can slow down the app quite a lot.
const validation_layers = if (builtin.mode == .Debug)
    [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
else
    &.{};

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

/// We link directly against the Vulkan loader (libvulkan.so.1), so
/// we can get the base entry point directly rather than having to
/// dlopen it. All other functions are loaded through it.
extern fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction;

fn getProcAddress(instance: vk.Instance, name: [*:0]const u8) ?vk.PfnVoidFunction {
    return vkGetInstanceProcAddr(instance, name);
}

/// The allocator used to initialize this device. Needed to free
/// our state on deinit.
alloc: Allocator,

instance: vk.InstanceProxy,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
dispatch: vk.DeviceProxy,

graphics_queue: Queue,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32,

/// The context for exporting dmabufs, or null if the device doesn't
/// support it.
dmabuf: ?Dmabuf,

/// The pieces used by our GPU resource types (buffers, textures,
/// targets): device memory allocation and one-shot uploads. These
/// are passed to the resources by value, as needed.
dev_alloc: MemoryAllocator,
transfers: Transfers,

/// Debug messenger, only set in debug builds.
debug_messenger: ?vk.DebugUtilsMessengerEXT = null,

/// A queue with its family index.
pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
};

/// The device state needed to allocate device memory. A value type,
/// passed to (and stored by) our GPU resource types so that they
/// don't need to pin the whole device context.
pub const MemoryAllocator = struct {
    dispatch: vk.DeviceProxy,
    props: vk.PhysicalDeviceMemoryProperties,

    pub fn init(
        instance: vk.InstanceProxy,
        pdev: vk.PhysicalDevice,
        dispatch: vk.DeviceProxy,
    ) MemoryAllocator {
        return .{
            .dispatch = dispatch,
            .props = instance.getPhysicalDeviceMemoryProperties(pdev),
        };
    }

    /// Find a memory type index that supports the given property
    /// flags, from the given allowed bits.
    pub fn findMemoryTypeIndex(
        self: MemoryAllocator,
        bits: u32,
        flags: vk.MemoryPropertyFlags,
    ) ?u32 {
        for (self.props.memory_types[0..self.props.memory_type_count], 0..) |mem_type, i| {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0 and
                mem_type.property_flags.contains(flags))
            {
                return @intCast(i);
            }
        }

        return null;
    }

    /// Allocate device memory for the given requirements. If
    /// `export_handle` is set, the memory will be allocated so that
    /// it can be exported with the given external handle type.
    pub fn allocate(
        self: MemoryAllocator,
        requirements: vk.MemoryRequirements,
        flags: vk.MemoryPropertyFlags,
        export_handle: ?vk.ExternalMemoryHandleTypeFlags,
    ) !vk.DeviceMemory {
        var export_info: ?vk.ExportMemoryAllocateInfo = if (export_handle) |handle|
            .{ .handle_types = handle }
        else
            null;

        return try self.dispatch.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = self.findMemoryTypeIndex(
                requirements.memory_type_bits,
                flags,
            ) orelse return error.MemoryTypeNotFound,
            .p_next = if (export_info) |*i| i else null,
        }, null);
    }
};

/// Object used to submit one-off GPU work not done on specific frames,
/// such as uploading texture data.
pub const Transfers = struct {
    dispatch: vk.DeviceProxy,
    queue: vk.Queue,
    pool: vk.CommandPool,
    fence: vk.Fence,
    cmd: vk.CommandBufferProxy,

    uploading: bool = false,

    pub fn init(dispatch: vk.DeviceProxy, queue: Queue) !Transfers {
        const pool = try dispatch.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = queue.family,
        }, null);
        errdefer dispatch.destroyCommandPool(pool, null);
        const fence = try dispatch.createFence(&.{}, null);
        errdefer dispatch.destroyFence(fence, null);

        var cmd: [1]vk.CommandBuffer = undefined;
        try dispatch.allocateCommandBuffers(&.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, &cmd);

        return .{
            .dispatch = dispatch,
            .queue = queue.handle,
            .pool = pool,
            .fence = fence,
            .cmd = .init(cmd[0], dispatch.wrapper),
        };
    }

    pub fn deinit(self: Transfers) void {
        self.dispatch.destroyFence(self.fence, null);
        self.dispatch.destroyCommandPool(self.pool, null);
    }

    /// Begin a one-shot command buffer on the graphics queue. Record
    /// into the returned command buffer and then pass it to `endOneShot`
    /// to submit it and wait for it to complete.
    pub fn beginOneShot(self: *Transfers) !vk.CommandBufferProxy {
        // One-shot command buffers must be properly paired.
        assert(!self.uploading);
        self.uploading = true;

        try self.cmd.resetCommandBuffer(.{});
        try self.cmd.beginCommandBuffer(&.{
            .flags = .{ .one_time_submit_bit = true },
        });

        return self.cmd;
    }

    /// End, submit and wait for a one-shot command buffer started with
    /// `beginOneShot`.
    pub fn endOneShot(self: *Transfers, cmd: vk.CommandBufferProxy) !void {
        assert(self.uploading);
        defer self.uploading = false;

        try cmd.endCommandBuffer();

        try self.dispatch.resetFences(&.{self.fence});
        try self.dispatch.queueSubmit(self.queue, &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmd.handle},
        }}, self.fence);

        _ = try self.dispatch.waitForFences(
            &.{self.fence},
            .true,
            std.math.maxInt(u64),
        );
    }
};

/// The instance and physical device context needed to query and
/// export dmabufs. Null when the device doesn't support dmabuf
/// export.
pub const Dmabuf = struct {
    instance: vk.InstanceProxy,
    pdev: vk.PhysicalDevice,
};

/// Construct an image memory barrier covering all of the color data
/// of an image, with queue family ownership ignored. This is the
/// common case for our texture and render target layout transitions.
pub fn colorImageBarrier(
    image: vk.Image,
    src_access_mask: vk.AccessFlags,
    dst_access_mask: vk.AccessFlags,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) vk.ImageMemoryBarrier {
    return .{
        .src_access_mask = src_access_mask,
        .dst_access_mask = dst_access_mask,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
}

/// Initialize a new device.
pub fn init(alloc: Allocator) !Device {
    const vkb = BaseWrapper.load(&getProcAddress);

    if (validation_layers.len > 0) {
        const layers = try vkb.enumerateInstanceLayerPropertiesAlloc(alloc);
        defer alloc.free(layers);

        for (validation_layers) |val| {
            for (layers) |layer| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(&layer.layer_name, 0),
                    std.mem.span(val),
                )) break;
            } else {
                log.warn("Vulkan validation layer not found={s}", .{val});
            }
        }
    }

    // Pipe Vulkan messages to our logger.
    const debug_extensions = [_][*:0]const u8{vk.extensions.ext_debug_utils.name};

    const app_version = vk.makeApiVersion(
        build_config.version.major,
        build_config.version.minor,
        build_config.version.patch,
        0,
    );
    const instance_handle = try vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "Ghostty",
            .application_version = app_version.toU32(),
            .p_engine_name = "Ghostty",
            .engine_version = app_version.toU32(),
            .api_version = vk.API_VERSION_1_2.toU32(),
        },
        // We render offscreen and don't interact with any window
        // system, so we don't need any surface extensions beyond
        // debugging.
        .enabled_extension_count = debug_extensions.len,
        .pp_enabled_extension_names = &debug_extensions,
        .enabled_layer_count = validation_layers.len,
        .pp_enabled_layer_names = &validation_layers,
    }, null);

    const instance_wrapper = try alloc.create(InstanceWrapper);
    errdefer alloc.destroy(instance_wrapper);
    instance_wrapper.* = InstanceWrapper.load(
        instance_handle,
        vkb.dispatch.vkGetInstanceProcAddr.?,
    );
    const instance: vk.InstanceProxy = .init(instance_handle, instance_wrapper);
    errdefer instance.destroyInstance(null);

    // Set up the debug messenger to route validation messages to
    // our log.
    const debug_messenger = try instance.createDebugUtilsMessengerEXT(&.{
        .message_severity = .{
            // Only log verbose and info messages in debug mode
            .verbose_bit_ext = builtin.mode == .Debug,
            .info_bit_ext = builtin.mode == .Debug,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = &debugUtilsMessengerCallback,
        .p_user_data = null,
    }, null);

    // Choose a physical device.
    const pdev = chooseDevice(instance, alloc) orelse return error.NoDevice;

    // Grab our device metadata.
    const props = instance.getPhysicalDeviceProperties(pdev);
    const device_name = std.mem.sliceTo(&props.device_name, 0);

    if (props.api_version < vk.API_VERSION_1_2.toU32()) {
        log.warn(
            "Vulkan device is too old. Ghostty requires Vulkan 1.2. device={s}",
            .{device_name},
        );
        return error.VulkanOutdated;
    }

    const max_texture_size = props.limits.max_image_dimension_2d;

    // Check for required features.
    // Our required feature set is Vulkan 1.2 with dynamic rendering.
    //
    // Shader draw parameters is required since our Slang shader always
    // emits SPIR-V with it assumed to be available. While it is part of
    // Vulkan 1.1, we still need to manually opt into the feature. Similarly,
    // timeline semaphors are already part of Vulkan 1.2, but we need to
    // opt in explicitly.
    //
    // Dynamic rendering wouldn't be part of Vulkan core until Vulkan 1.3,
    // which would bar us from using the Vulkan renderer on macOS via
    // MoltenVK. Luckily, it is supported on pretty much all desktop
    // Vulkan 1.2 drivers, so it's safe to assume it here.
    var vulkan11_features: vk.PhysicalDeviceVulkan11Features = .{
        .shader_draw_parameters = .true,
    };
    var vulkan12_features: vk.PhysicalDeviceVulkan12Features = .{
        .p_next = &vulkan11_features,
        .timeline_semaphore = .true,
    };
    var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{
        .p_next = &vulkan12_features,
        .dynamic_rendering = .true,
    };
    var features2: vk.PhysicalDeviceFeatures2 = .{
        .p_next = &dynamic_rendering_features,
        .features = .{},
    };
    instance.getPhysicalDeviceFeatures2(pdev, &features2);
    if (vulkan11_features.shader_draw_parameters != .true or
        vulkan12_features.timeline_semaphore != .true or
        dynamic_rendering_features.dynamic_rendering != .true)
    {
        log.warn(
            "Vulkan device does not support required features, device={s}",
            .{device_name},
        );
        return error.VulkanFeatureMissing;
    }

    // Check which device extensions are supported.
    const ext_props = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, alloc);
    defer alloc.free(ext_props);

    req: for (required_device_extensions) |ext| {
        for (ext_props) |prop| {
            if (std.mem.eql(u8, std.mem.sliceTo(&prop.extension_name, 0), std.mem.span(ext))) continue :req;
        }
        log.warn(
            "Vulkan device does not support required extension {s}, device={s}",
            .{ ext, device_name },
        );
        return error.VulkanExtensionMissing;
    }

    var supports_dmabuf = true;
    var enabled_extensions: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_extensions.deinit(alloc);
    for (required_device_extensions) |ext| {
        try enabled_extensions.append(alloc, ext);
    }
    opt: for (optional_device_extensions) |ext| {
        for (ext_props) |prop| {
            if (std.mem.eql(u8, std.mem.sliceTo(&prop.extension_name, 0), std.mem.span(ext))) {
                try enabled_extensions.append(alloc, ext);
                continue :opt;
            }
        }

        log.warn(
            "Vulkan device does not support optional extension {s}, device={s}",
            .{ ext, device_name },
        );
        if (std.mem.orderZ(u8, ext, vk.extensions.khr_external_memory_fd.name) == .eq or
            std.mem.orderZ(u8, ext, vk.extensions.ext_external_memory_dma_buf.name) == .eq)
            supports_dmabuf = false;
    }

    // Find a queue family with graphics support.
    const queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, alloc);
    defer alloc.free(queue_families);
    const graphics_family: u32 = fam: {
        for (queue_families, 0..) |family, i| {
            if (family.queue_flags.graphics_bit) {
                break :fam @intCast(i);
            }
        }

        log.warn(
            "Vulkan device has no graphics queue, device={s}",
            .{device_name},
        );
        return error.VulkanFeatureMissing;
    };

    // Create the logical device.
    const queue_priority = [_]f32{1.0};
    const dev = try instance.createDevice(pdev, &.{
        .queue_create_info_count = 1,
        .p_queue_create_infos = &.{
            .{
                .queue_family_index = graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &queue_priority,
            },
        },
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .p_enabled_features = null,
        .p_next = &dynamic_rendering_features,
    }, null);

    const device_wrapper = try alloc.create(DeviceWrapper);
    errdefer alloc.destroy(device_wrapper);
    device_wrapper.* = .load(
        dev,
        instance.wrapper.dispatch.vkGetDeviceProcAddr.?,
    );

    const dev_proxy: vk.DeviceProxy = .init(dev, device_wrapper);
    errdefer dev_proxy.destroyDevice(null);

    log.info("using Vulkan device {s} dmabuf={}", .{
        device_name,
        supports_dmabuf,
    });

    const queue_handle = dev_proxy.getDeviceQueue(graphics_family, 0);

    const transfers: Transfers = try .init(dev_proxy, .{
        .handle = queue_handle,
        .family = graphics_family,
    });
    errdefer transfers.deinit();

    return .{
        .alloc = alloc,
        .instance = instance,
        .pdev = pdev,
        .props = props,
        .dispatch = dev_proxy,
        .graphics_queue = .{
            .handle = queue_handle,
            .family = graphics_family,
        },
        .max_texture_size = max_texture_size,
        .dmabuf = if (supports_dmabuf) .{
            .instance = instance,
            .pdev = pdev,
        } else null,
        .dev_alloc = .init(instance, pdev, dev_proxy),
        .transfers = transfers,
        .debug_messenger = if (debug_messenger != .null_handle) debug_messenger else null,
    };
}

/// Tear down the device. This must not be called while any surface
/// renderers still exist. The device cannot be used after this.
pub fn deinit(self: *Device) void {
    if (self.debug_messenger) |messenger| {
        self.instance.destroyDebugUtilsMessengerEXT(messenger, null);
    }

    self.transfers.deinit();

    self.dispatch.destroyDevice(null);
    self.instance.destroyInstance(null);

    self.alloc.destroy(self.dispatch.wrapper);
    self.alloc.destroy(self.instance.wrapper);

    self.* = undefined;
}

/// Choose a physical device, mirroring the Metal renderer's
/// `chooseDevice`: we skip devices that can't render (software
/// implementations, analogous to Metal's headless devices) and
/// otherwise prefer integrated GPUs for battery life and thermals,
/// falling back to whatever non-software device is available.
fn chooseDevice(
    instance: vk.InstanceProxy,
    alloc: Allocator,
) ?vk.PhysicalDevice {
    const pdevs = instance.enumeratePhysicalDevicesAlloc(alloc) catch return null;
    defer alloc.free(pdevs);

    var chosen: ?vk.PhysicalDevice = null;
    for (pdevs) |pdev| {
        const props = instance.getPhysicalDeviceProperties(pdev);

        // Skip software implementations (llvmpipe, etc.).
        if (props.device_type == .cpu) continue;

        chosen = pdev;

        // Integrated GPUs are better for battery life and thermals,
        // so we prefer them. (Unlike Metal we can't detect removable
        // GPUs, so we don't have an eGPU preference.)
        if (props.device_type == .integrated_gpu) break;
    }

    return chosen;
}

fn debugUtilsMessengerCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    const severity_str: []const u8 = if (severity.verbose_bit_ext)
        "verbose"
    else if (severity.info_bit_ext)
        "info"
    else if (severity.warning_bit_ext)
        "warning"
    else if (severity.error_bit_ext)
        "error"
    else
        "unknown";

    const type_str: []const u8 = if (msg_type.general_bit_ext)
        "general"
    else if (msg_type.validation_bit_ext)
        "validation"
    else if (msg_type.performance_bit_ext)
        "performance"
    else
        "unknown";

    const message: [*:0]const u8 = if (callback_data) |data|
        data.p_message orelse "(no message)"
    else
        "(no message)";

    log.debug(
        "[{s}][{s}] {s}",
        .{ severity_str, type_str, message },
    );
    return .false;
}
