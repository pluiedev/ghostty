//! Compiled result of `shaders.slang`.
//!
//! Renderers can include the `shaders` module and specify it as this type,
//! in order to access the compiled shader code for the target renderer,
//! as well as a table of binding types and their corresponding position:
//! ```
//! const Compiled = @import("shaders/Compiled.zig");
//! const shaders: Compiled = @import("shaders");
//!
//! // Only one kind of code is generated, the exact kind of which
//! // depends on the current selected renderer. On OpenGL, for instance,
//! // only the `glsl` variant will be active.
//! const shader_code = shaders.code.glsl;
//! const binding = shaders.binding(.uniforms);
//! ```
//!
//! Keep synchronized with `shaders.slang` at all times.

const Compiled = @This();

const std = @import("std");
const build_options = @import("options");

const Allocator = std.mem.Allocator;
const slang = @import("slang");

const log = std.log.scoped(.shader_compile);

code: Code,
table: Bindings,

/// Entrypoints of `shaders.slang`, in declaration order.
pub const Entrypoint = enum {
    full_screen_vertex,
    bg_color_fragment,
    bg_image_vertex,
    bg_image_fragment,
    cell_bg_fragment,
    cell_text_vertex,
    cell_text_fragment,
    image_vertex,
    image_fragment,
};

/// The compiled shader code, tagged by target.
pub const Code = union(Target) {
    /// The Metal library (`.metallib`).
    metal: []const u8,
    /// The GLSL source for every entry point.
    glsl: std.enums.EnumFieldStruct(Entrypoint, []const u8, null),
};

/// The global shader resources in the order they are declared in
/// `shaders/shaders.slang`. Slang assigns bindings in declaration order,
/// so the order here must be kept in sync with the shader.
pub const Resource = enum {
    image_texture,
    uniforms,
    bg_cells,
    atlas_grayscale,
    atlas_color,

    pub fn kind(self: Resource) Binding.Kind {
        return switch (self) {
            .image_texture,
            .atlas_grayscale,
            .atlas_color,
            => .combined_image_sampler,
            .uniforms,
            => .uniform_buffer,
            .bg_cells,
            => .storage_buffer,
        };
    }
};

pub const Target = enum {
    metal,
    glsl,
};

/// The binding of a single resource for a single target.
pub const Binding = union(enum) {
    /// Register-style binding. Buffers, textures and samplers each have
    /// their own index space.
    ///
    /// Currently used by Metal.
    registers: Registers,

    /// Descriptor-style binding. All GPU resources bind to the same
    /// index space regardless of resource type.
    ///
    /// Currently used by OpenGL.
    descriptor: u32,

    /// The kind of a binding as Slang laid it out.
    pub const Kind = enum {
        uniform_buffer,
        storage_buffer,
        combined_image_sampler,
    };

    pub const Registers = union(Kind) {
        uniform_buffer: u32, // buffer index
        storage_buffer: u32, // buffer index
        combined_image_sampler: struct {
            texture: u32,
            sampler: u32,
        },
    };
};

/// The binding of every resource, keyed by resource name. Generated from
/// the `Resource` enum so the two can't drift apart. This is the shape of
/// the `table` field of `shaders.zon`.
pub const Bindings = std.enums.EnumFieldStruct(Resource, Binding, null);

/// Builds the binding table from the binding of every `Resource`.
pub fn initBindings(values: std.EnumArray(Resource, Binding)) Bindings {
    var table: Bindings = undefined;
    inline for (comptime std.meta.tags(Resource)) |resource| {
        @field(table, @tagName(resource)) = values.get(resource);
    }
    return table;
}

/// Returns the binding of `resource` in the configured target's binding
/// space.
pub fn binding(self: Compiled, comptime resource: Resource) BindingSpace {
    return switch (table_target) {
        .metal => @field(self.table, @tagName(resource)).registers,
        .glsl => @field(self.table, @tagName(resource)).descriptor,
    };
}

/// The binding space resources are bound in for the configured target.
pub const BindingSpace = switch (table_target) {
    .metal => Binding.Registers,
    .glsl => u32,
};

/// The target the shader table was generated for, based on the
/// configured renderer.
pub const table_target: Target = switch (build_options.renderer) {
    .metal => .metal,
    .opengl => .glsl,
};

/// The binding index the shadertoy post-processing shaders expect for
/// their uniform block. These shaders are compiled at runtime
/// (see `shadertoy.zig`) and use a hardcoded convention defined by
/// `shaders/shadertoy_prefix.glsl`, so they can't participate in the
/// generated table above.
pub const post_uniforms_binding: u32 = 1;

pub fn main(init: std.process.Init) !void {
    // Since this is a one-shot tool we can use the provided
    // arena to allocate and deallocate everything in one go.
    const alloc = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(alloc);
    _ = it.skip(); // argv[0]
    const source_path = it.next() orelse return error.SourcePathRequired;
    const out_path = it.next() orelse return error.OutputPathRequired;

    const global_session = try slang.createGlobalSession(.{});

    // Slang's command-line default for GLSL-family targets is row-major
    // output, which corresponds to the "column-major" compiler option.
    var session_options: std.ArrayList(slang.CompilerOptionEntry) = .empty;
    try session_options.append(alloc, .matrix_layout_column);

    // Build the target and its options for the configured renderer.
    var target_options: std.ArrayList(slang.CompilerOptionEntry) = .empty;
    const target_kind: Compiled.Target = switch (build_options.renderer) {
        .metal => metal: {
            // For the register-style Metal target, register 0 is reserved
            // for the vertex buffer, so buffer registers are shifted by 1.
            try target_options.append(alloc, .vulkanBindShift(0, .buffer, 1));

            // Preserve the deployment target of the configured build.
            if (build_options.metal_min_os_version) |version| {
                const args = try std.fmt.allocPrintSentinel(
                    alloc,
                    "-mmacos-version-min={s}",
                    .{version},
                    0,
                );
                try target_options.append(alloc, .downstreamArgs("metal", args));
            }
            break :metal .metal;
        },
        .opengl => .glsl,
    };
    const target: slang.TargetDesc = .{
        .format = switch (target_kind) {
            .metal => .metal_lib,
            .glsl => .glsl,
        },
        .compiler_option_entries = if (target_options.items.len > 0)
            target_options.items.ptr
        else
            null,
        .compiler_option_entry_count = @intCast(target_options.items.len),
    };

    const session = try global_session.createSession(.{
        .targets = &.{target},
        .compiler_option_entries = session_options.items,
    });
    defer session.release();

    // Load the shader module from the given file.
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        source_path,
        alloc,
        .unlimited,
        .of(u8),
        0, // Needs to be NUL-terminated for Slang
    );
    const module_name = try alloc.dupeZ(u8, std.fs.path.stem(source_path));
    const source_path_z = try alloc.dupeZ(u8, source_path);

    const module = session.loadModuleFromSource(
        module_name,
        source_path_z,
        source,
        null,
    ) orelse {
        log.err("failed to load module {s}", .{source_path});
        return error.LoadModuleFailed;
    };
    defer module.release();

    // Compose the module with all of its entry points and link once. The
    // other targets compile the whole program, while GLSL needs each entry
    // point extracted individually.
    const entrypoints = comptime std.meta.tags(Entrypoint);
    var components: [entrypoints.len + 1]*slang.IComponentType = undefined;
    components[0] = @ptrCast(module);
    inline for (entrypoints, 1..) |field, i| {
        components[i] = try module.findEntryPointByName(@tagName(field));
    }
    defer for (components[1..]) |comp| comp.release();

    var composite: *slang.IComponentType = undefined;
    try session.createCompositeComponentType(&components, &composite, null);
    defer composite.release();

    const program = try composite.link(null);
    defer program.release();

    const layout = program.getLayout(0, null) orelse return error.NoLayout;
    const compiled: Compiled = .{
        .code = try getCode(alloc, target_kind, program),
        .table = try getBindings(layout),
    };

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try std.zon.stringify.serialize(
        compiled,
        // The ZON is not user-facing so there's zero need for whitespace.
        .{ .whitespace = false },
        &file_writer.interface,
    );
    try file_writer.flush();
}

fn getCode(
    alloc: Allocator,
    comptime target: Compiled.Target,
    program: *slang.IComponentType,
) !Compiled.Code {
    switch (target) {
        .metal => {
            var code: *slang.IBlob = undefined;
            try program.getTargetCode(0, &code, null);
            defer code.release();

            return @unionInit(Compiled.Code, @tagName(target), code.getBuffer());
        },

        .glsl => {
            const entrypoints = comptime std.meta.tags(Entrypoint);
            var sources: [entrypoints.len][]const u8 = undefined;
            for (&sources, 0..) |*s, i| {
                var code: *slang.IBlob = undefined;
                try program.getEntryPointCode(@intCast(i), 0, &code, null);
                defer code.release();
                s.* = try alloc.dupe(u8, code.getBuffer());
            }

            var glsl: @FieldType(Compiled.Code, "glsl") = undefined;
            inline for (entrypoints, 0..) |field, i| {
                @field(glsl, @tagName(field)) = sources[i];
            }
            return .{ .glsl = glsl };
        },
    }
}

fn getBindings(layout: *slang.ShaderReflection) !Compiled.Bindings {
    const resources = comptime std.meta.tags(Compiled.Resource);
    var values: std.EnumArray(Compiled.Resource, Compiled.Binding) = .initUndefined();

    const param_count = layout.getParameterCount();
    if (param_count != resources.len) {
        log.err(
            "shader has {d} global resources, expected {d}; update Compiled.zig",
            .{ param_count, resources.len },
        );
        return error.ResourceMismatch;
    }

    inline for (resources, 0..) |resource, pi| {
        const param = layout.getParameterByIndex(@intCast(pi));

        const name = param.getName();
        if (std.mem.orderZ(u8, name, @tagName(resource)) != .eq) {
            log.err(
                \\shader global at index {d} is '{s}' but '{t}' is expected;
                \\reorder the globals in Compiled.zig to match shaders.slang
            ,
                .{ pi, name, resource },
            );
            return error.ResourceMismatch;
        }

        values.set(resource, reflectBinding(param) catch |err| {
            log.err("failed to reflect binding of shader global '{s}'", .{name});
            return err;
        });
    }

    return Compiled.initBindings(values);
}

fn reflectBinding(param: *slang.VariableLayoutReflection) !Compiled.Binding {
    // The kind comes from the resource type, which is target independent.
    const ty = param.getType();
    const kind: Compiled.Binding.Kind = switch (ty.getKind()) {
        .constant_buffer => .uniform_buffer,
        .shader_storage_buffer => .storage_buffer,
        .resource => blk: {
            const shape = ty.getResourceShape();
            break :blk switch (shape.base) {
                .structured_buffer => .storage_buffer,
                else => .combined_image_sampler,
            };
        },
        else => {
            log.err("type {t} of shader global '{s}' is unhandled", .{
                ty.getKind(),
                param.getName(),
            });
            return error.UnhandledResourceKind;
        },
    };

    return switch (build_options.renderer) {
        // Metal binds buffers, textures and samplers in separate index spaces.
        // A resource can occupy more than one register (e.g. a combined image
        // sampler has both a texture and a sampler binding).
        .metal => .{ .registers = switch (kind) {
            .uniform_buffer => .{ .uniform_buffer = try registerIndex(param, .constant_buffer) },
            .storage_buffer => .{ .storage_buffer = try registerIndex(param, .constant_buffer) },
            .combined_image_sampler => .{ .combined_image_sampler = .{
                .texture = try registerIndex(param, .shader_resource),
                .sampler = try registerIndex(param, .sampler_state),
            } },
        } },

        // OpenGL and Vulkan instead use unified descriptor slot indices.
        .opengl, .vulkan => desc: {
            const index = param.getBindingIndex();
            if (index < 0) return error.NoBinding;
            break :desc .{ .descriptor = @intCast(index) };
        },
    };
}

fn bindingIndex(param: *slang.VariableLayoutReflection) error{NoBinding}!u32 {
    const index = param.getBindingIndex();
    if (index < 0) return error.NoBinding;
    return @intCast(index);
}

/// Returns the register binding index the given parameter occupies in the
/// given category, or `error.NoBinding` if it doesn't occupy one.
fn registerIndex(
    param: *slang.VariableLayoutReflection,
    category: slang.ParameterCategory,
) error{NoBinding}!u32 {
    for (0..param.getCategoryCount()) |ci| {
        if (param.getCategoryByIndex(@intCast(ci)) == category) {
            return @intCast(param.getOffset(category));
        }
    }
    return error.NoBinding;
}
