//! An abstraction over a GPU buffer.
const std = @import("std");

const vk = @import("vulkan");
const Device = @import("Device.zig");

/// Options for initializing a buffer.
pub const Options = struct {
    /// The device memory allocator used to back the buffer.
    dev_alloc: Device.MemoryAllocator,

    /// Usage flags for the buffer. Note that CPU-written buffers are
    /// always host-visible and host-coherent.
    usage: vk.BufferUsageFlags = .{},
};

/// Vulkan data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with Vulkan.
///
/// Buffers are host-visible and persistently mapped: `sync` writes the
/// data with a plain memcpy and no further synchronization is required
/// to make it visible to the GPU.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying Vulkan buffer handle. Exposed so that buffers
        /// can be passed to render pass steps.
        buffer: vk.Buffer,

        /// Options this buffer was allocated with. Holds the device
        /// context (dispatch, memory) needed to use the buffer.
        opts: Options,

        /// The device memory backing the buffer.
        memory: vk.DeviceMemory,

        /// Persistent mapping of the memory.
        mapped: [*]u8,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated. The
        /// contents are undefined.
        pub fn init(opts: Options, len: usize) !Self {
            const size: vk.DeviceSize = @max(@sizeOf(T) * len, 1);
            const dispatch = opts.dev_alloc.dispatch;

            const buffer = try dispatch.createBuffer(&.{
                .size = size,
                .usage = opts.usage,
                .sharing_mode = .exclusive,
            }, null);
            errdefer dispatch.destroyBuffer(buffer, null);

            const requirements = dispatch.getBufferMemoryRequirements(buffer);

            // Host-visible so that we can write the contents directly.
            // Coherent so that no explicit flushing is required.
            const memory = try opts.dev_alloc.allocate(
                requirements,
                .{ .host_visible_bit = true, .host_coherent_bit = true },
                null,
            );
            errdefer dispatch.freeMemory(memory, null);

            try dispatch.bindBufferMemory(buffer, memory, 0);

            const mapped: [*]u8 = @ptrCast(
                try dispatch.mapMemory(memory, 0, vk.WHOLE_SIZE, .{}),
            );

            return .{
                .buffer = buffer,
                .opts = opts,
                .memory = memory,
                .mapped = mapped,
                .len = len,
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            var self = try init(opts, data.len);
            errdefer self.deinit();

            @memcpy(
                self.mapped[0 .. data.len * @sizeOf(T)],
                std.mem.sliceAsBytes(data),
            );
            return self;
        }

        pub fn deinit(self: Self) void {
            self.opts.dev_alloc.dispatch.unmapMemory(self.memory);
            self.opts.dev_alloc.dispatch.destroyBuffer(self.buffer, null);
            self.opts.dev_alloc.dispatch.freeMemory(self.memory, null);
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            const byte_len = data.len * @sizeOf(T);

            // If we need more space than our buffer has, we need to reallocate.
            if (data.len > self.len) {
                const opts = self.opts;
                self.deinit();
                self.* = try init(opts, data.len * 2);
            }

            @memcpy(
                self.mapped[0..byte_len],
                std.mem.sliceAsBytes(data),
            );
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more space than our buffer has, we need to reallocate.
            if (total_len > self.len) {
                const opts = self.opts;
                self.deinit();
                self.* = try init(opts, total_len * 2);
            }

            var offset: usize = 0;
            for (lists) |list| {
                const byte_len = list.items.len * @sizeOf(T);
                @memcpy(
                    self.mapped[offset .. offset + byte_len],
                    @as([*]const u8, @ptrCast(list.items.ptr))[0..byte_len],
                );
                offset += byte_len;
            }

            return total_len;
        }
    };
}
