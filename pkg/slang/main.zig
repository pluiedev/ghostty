//! Zig bindings for the subset of the Slang C API that Ghostty uses.
//!
//! Vendored from https://github.com/raugl/slang-zig (MIT license) and
//! trimmed down to the pieces we actually use. Unlike upstream, we link
//! against a system-installed libslang rather than downloading prebuilt
//! Slang binaries.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.slang);

pub const LogDiagnostics = enum {
    always,
    only_for_null,
    never,
};

const log_diagnostics: LogDiagnostics = .only_for_null;

threadlocal var diagnostics_blob: *IBlob = @ptrFromInt(0x8);

fn getDiagnosticsPtr(out_diagnostics: ?**IBlob) ?**IBlob {
    return switch (log_diagnostics) {
        .always, .only_for_null => out_diagnostics orelse &diagnostics_blob,
        .never => out_diagnostics,
    };
}

fn logDiagnostics(diagnostics: ?**IBlob, out_diagnostics: ?**IBlob) void {
    if (log_diagnostics != .never and out_diagnostics == null and @intFromPtr(diagnostics_blob) != 0x8) {
        log.err("{s}", .{diagnostics_blob.getBuffer()});
        diagnostics_blob.release();
        diagnostics_blob = @ptrFromInt(0x8);
    } else if (log_diagnostics == .always) {
        log.err("{s}", .{diagnostics.?.*.getBuffer()});
    }
}

const mcall: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const API_VERSION = 0;

pub const Result = enum(i32) {
    ok = 0,
    fail = makeError(facility_win_general, 0x4005),
    not_implemented = makeError(facility_win_general, 0x4001),
    no_interface = makeError(facility_win_general, 0x4002),
    aborted = makeError(facility_win_general, 0x4004),

    invalid_handle = makeError(facility_win_api, 6),
    invalid_arg = makeError(facility_win_api, 0x57),
    out_of_memory = makeError(facility_win_api, 0xe),

    buffer_too_small = makeError(facility_core, 1),
    uninitialized,
    pending,
    cannot_open,
    not_found,
    internal_fail,
    not_available,
    time_out,
    _,

    pub const facility_win_general = 0x0;
    pub const facility_win_interface = 0x4;
    pub const facility_win_api = 0x7;
    pub const facility_base = 0x200;
    pub const facility_core = facility_base;
    pub const facility_internal = facility_base + 1;
    pub const facility_external_base = 0x210;

    pub fn makeError(facility: u15, code: u16) i32 {
        return @bitCast(@as(u32, @intCast(facility)) << 16 | @as(u32, @intCast(code)) | 0x80000000);
    }

    pub fn failed(self: Result) bool {
        return @intFromEnum(self) < 0;
    }

    pub fn check(self: Result) Error!void {
        switch (self) {
            .ok => return,
            .fail => return error.Fail,
            .not_implemented => return error.NotImplemented,
            .no_interface => return error.NoInterface,
            .aborted => return error.Aborted,
            .invalid_handle => return error.InvalidHandle,
            .invalid_arg => return error.InvalidArg,
            .out_of_memory => return error.OutOfMemory,
            .buffer_too_small => return error.BufferTooSmall,
            .uninitialized => return error.Uninitialized,
            .cannot_open => return error.CannotOpen,
            .not_found => return error.NotFound,
            .internal_fail => return error.InternalFail,
            .not_available => return error.NotAvailable,
            .time_out => return error.TimeOut,
            else => if (self.failed()) return error.Fail,
        }
    }
};

pub const Error = error{
    Fail,
    NotImplemented,
    NoInterface,
    Aborted,
    InvalidHandle,
    InvalidArg,
    OutOfMemory,
    BufferTooSmall,
    Uninitialized,
    CannotOpen,
    NotFound,
    InternalFail,
    NotAvailable,
    TimeOut,
};

pub const UUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn init(a: u32, b: u16, c: u16, d: [8]u8) UUID {
        return UUID{ .data1 = a, .data2 = b, .data3 = c, .data4 = d };
    }
};

pub const LanguageVersion = enum(i32) {
    unknown = 0,
    legacy = 2018,
    @"2025" = 2025,
    @"2026" = 2026,
};

pub const GlobalSessionDesc = extern struct {
    _structure_size: u32 = @sizeOf(@This()),
    api_version: u32 = API_VERSION,
    min_language_version: LanguageVersion = .@"2025",
    enable_glsl: bool = false,
    _reserved: [16]u32 = undefined,
};

pub const SessionFlags = enum(u32) {
    none = 0,
};

pub const PreprocessorMacroDesc = extern struct {
    name: [*:0]const u8,
    value: [*:0]const u8,
};

pub const CompileTarget = enum(i32) {
    unknown = 0,
    none = 1,
    glsl = 2,
    spirv = 6,
    metal = 24,
    metal_lib = 25,
    _,
};

pub const TargetFlags = packed struct(u32) {
    _pad0: u4 = 0,
    parameter_blocks_use_register_spaces: bool = false,
    _pad1: u3 = 0,
    generate_whole_program: bool = false,
    dump_ir: bool = false,
    generate_spirv_directly: bool = false,
    _pad2: u21 = 0,
};

pub const FloatingPointMode = enum(i32) {
    default = 0,
    fast,
    precise,
};

pub const LineDirectiveMode = enum(i32) {
    default = 0,
    none,
    standard,
    glsl,
    source_map,
};

pub const MatrixLayoutMode = enum(u32) {
    unknown = 0,
    row_major,
    column_major,
};

pub const ProfileID = enum(i32) {
    unknown = 0,
    _,
};

pub const CompilerOptionValueKind = enum(i32) {
    int,
    string,
};

pub const CompilerOptionValue = extern struct {
    kind: CompilerOptionValueKind = .int,
    int_value_0: i32 = 0,
    int_value_1: i32 = 0,
    string_value_0: ?[*:0]const u8 = null,
    string_value_1: ?[*:0]const u8 = null,
};

pub const CompilerOptionName = enum(i32) {
    matrix_layout_column = 8,
    optimization = 46,
    vulkan_bind_shift = 48,
    downstream_args = 63,
    _,
};

pub const CompilerOptionEntry = extern struct {
    name: CompilerOptionName,
    value: CompilerOptionValue,

    /// Shifts the descriptor bindings of constant buffers within a set,
    /// the equivalent of the `-fvk-b-shift <shift> <set>` command line
    /// option.
    pub fn vulkanBindShift(set: u24, kind: VulkanShiftKind, shift: u32) CompilerOptionEntry {
        const v: packed struct(u32) {
            set: u24,
            kind: VulkanShiftKind,
        } = .{ .set = set, .kind = kind };

        return CompilerOptionEntry{
            .name = .vulkan_bind_shift,
            .value = .{
                .kind = .int,
                .int_value_0 = @bitCast(v),
                .int_value_1 = @intCast(shift),
            },
        };
    }

    pub const VulkanShiftKind = enum(u8) {
        buffer = 3,
    };

    /// Uses column-major matrix layout, the equivalent of the
    /// `-matrix-layout-column-major` command line option. This is Slang's
    /// default when compiling via the command line.
    pub const matrix_layout_column: CompilerOptionEntry = .{
        .name = .matrix_layout_column,
        .value = .{ .kind = .int, .int_value_0 = 1 },
    };

    /// Sets the optimization level, the equivalent of the `-O<level>`
    /// command line option (0 = none).
    pub fn optimization(level: u8) CompilerOptionEntry {
        return .{
            .name = .optimization,
            .value = .{ .kind = .int, .int_value_0 = @intCast(level) },
        };
    }

    /// Passes arguments to a downstream compiler, the equivalent of the
    /// `-X<compiler> <args>` command line option.
    pub fn downstreamArgs(
        compiler: [*:0]const u8,
        args: [*:0]const u8,
    ) CompilerOptionEntry {
        return .{
            .name = .downstream_args,
            .value = .{ .kind = .string, .string_value_0 = compiler, .string_value_1 = args },
        };
    }
};

pub const TargetDesc = extern struct {
    _structure_size: usize = @sizeOf(@This()),
    format: CompileTarget = .unknown,
    profile: ProfileID = .unknown,
    flags: TargetFlags = .{},
    floating_point_mode: FloatingPointMode = .default,
    line_directive_mode: LineDirectiveMode = .default,
    force_glsl_scalar_buffer_layout: bool = false,
    compiler_option_entries: ?[*]const CompilerOptionEntry = null,
    compiler_option_entry_count: u32 = 0,
};

pub const SessionDesc = struct {
    targets: []const TargetDesc = &.{},
    flags: SessionFlags = .none,
    default_matrix_layout_mode: MatrixLayoutMode = .row_major,
    search_paths: []const [*:0]const u8 = &.{},
    preprocessor_macros: []const PreprocessorMacroDesc = &.{},
    file_system: ?*IFileSystem = null,
    enable_effect_annotations: bool = false,
    allow_glsl_syntax: bool = false,
    compiler_option_entries: []const CompilerOptionEntry = &.{},
    skip_spirv_validation: bool = false,

    const Extern = extern struct {
        _structure_size: usize = @sizeOf(@This()),
        targets: ?[*]const TargetDesc = null,
        target_count: i64 = 0,
        flags: SessionFlags = .none,
        default_matrix_layout_mode: MatrixLayoutMode = .row_major,
        search_paths: ?[*]const [*:0]const u8 = null,
        search_path_count: i64 = 0,
        preprocessor_macros: ?[*]const PreprocessorMacroDesc = null,
        preprocessor_macro_count: i64 = 0,
        file_system: ?*IFileSystem = null,
        enable_effect_annotations: bool = false,
        allow_glsl_syntax: bool = false,
        compiler_options_entries: ?[*]const CompilerOptionEntry = null,
        compiler_option_entry_count: u32 = 0,
        skip_spirv_validation: bool = false,
    };

    fn toSlang(self: SessionDesc) Extern {
        for (self.targets) |desc| {
            if (desc.compiler_option_entries != null and desc.compiler_option_entry_count == 0) {
                log.err("Forgot to set 'TargetDesc.compiler_option_entry_count' for a target.", .{});
            }
        }

        return .{
            .targets = if (self.targets.len > 0) self.targets.ptr else null,
            .target_count = @intCast(self.targets.len),
            .flags = self.flags,
            .default_matrix_layout_mode = self.default_matrix_layout_mode,
            .search_paths = if (self.search_paths.len > 0) self.search_paths.ptr else null,
            .search_path_count = @intCast(self.search_paths.len),
            .preprocessor_macros = if (self.preprocessor_macros.len > 0) self.preprocessor_macros.ptr else null,
            .preprocessor_macro_count = @intCast(self.preprocessor_macros.len),
            .file_system = self.file_system,
            .enable_effect_annotations = self.enable_effect_annotations,
            .allow_glsl_syntax = self.allow_glsl_syntax,
            .compiler_options_entries = if (self.compiler_option_entries.len > 0) self.compiler_option_entries.ptr else null,
            .compiler_option_entry_count = @intCast(self.compiler_option_entries.len),
            .skip_spirv_validation = self.skip_spirv_validation,
        };
    }
};

pub const IFileSystem = opaque {};

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const queryInterface = IUnknown.Mixin(@This()).queryInterface;
    pub const addRef = IUnknown.Mixin(@This()).addRef;
    pub const release = IUnknown.Mixin(@This()).release;

    const VTable = extern struct {
        queryInterface: *const fn (this: *IUnknown, uuid: *const UUID, out_object: **anyopaque) callconv(mcall) Result,
        addRef: *const fn (this: *IUnknown) callconv(mcall) u32,
        release: *const fn (this: *IUnknown) callconv(mcall) u32,
    };

    fn Mixin(comptime T: type) type {
        return struct {
            pub fn queryInterface(self: *T, uuid: *const UUID, out_object: **anyopaque) !void {
                const vtable: *const VTable = @ptrCast(self.vtable);
                try vtable.queryInterface(@ptrCast(self), uuid, out_object).check();
            }

            pub fn addRef(self: *T) void {
                const vtable: *const VTable = @ptrCast(self.vtable);
                _ = vtable.addRef(@ptrCast(self));
            }

            pub fn release(self: *T) void {
                const vtable: *const VTable = @ptrCast(self.vtable);
                _ = vtable.release(@ptrCast(self));
            }
        };
    }
};

pub const IBlob = extern struct {
    vtable: *const VTable,

    pub const queryInterface = IUnknown.Mixin(@This()).queryInterface;
    pub const addRef = IUnknown.Mixin(@This()).addRef;
    pub const release = IUnknown.Mixin(@This()).release;
    pub const getBuffer = IBlob.Mixin(@This()).getBuffer;

    const VTable = extern struct {
        base: IUnknown.VTable,
        getBufferPointer: *const fn (this: *IBlob) callconv(mcall) ?[*]const u8,
        getBufferSize: *const fn (this: *IBlob) callconv(mcall) usize,
    };

    fn Mixin(comptime T: type) type {
        return struct {
            pub fn getBuffer(self: *T) []const u8 {
                const vtable: *const VTable = @ptrCast(self.vtable);
                const ptr = vtable.getBufferPointer(@ptrCast(self));
                if (ptr == null) return &.{};
                return ptr.?[0..vtable.getBufferSize(@ptrCast(self))];
            }
        };
    }
};

pub const IGlobalSession = extern struct {
    vtable: *const VTable,

    pub const release = IUnknown.Mixin(@This()).release;

    const VTable = extern struct {
        base: IUnknown.VTable,
        createSession: *const fn (this: *IGlobalSession, desc: *const SessionDesc.Extern, out_session: **ISession) callconv(mcall) Result,
    };

    pub fn createSession(self: *IGlobalSession, desc: SessionDesc) !*ISession {
        const vtable: *const VTable = @ptrCast(self.vtable);
        var session: *ISession = undefined;
        try vtable.createSession(@ptrCast(self), &desc.toSlang(), &session).check();
        return session;
    }
};

/// Create a global session, with the built-in core module.
pub fn createGlobalSession(desc: GlobalSessionDesc) !*IGlobalSession {
    var global_session: *IGlobalSession = undefined;
    try cdef.slang_createGlobalSession2(&desc, &global_session).check();
    return global_session;
}

pub const ISession = extern struct {
    vtable: *const VTable,

    pub const release = IUnknown.Mixin(@This()).release;

    const VTable = extern struct {
        base: IUnknown.VTable,
        getGlobalSession: *const anyopaque,
        loadModule: *const anyopaque,
        loadModuleFromSource: *const fn (this: *ISession, module_name: [*:0]const u8, path: [*:0]const u8, source: [*:0]const u8, source_size: usize, out_diagnostics: ?**IBlob) callconv(mcall) ?*IModule,
        createCompositeComponentType: *const fn (this: *ISession, component_types: [*]const *IComponentType, component_type_count: i64, out_composite: **IComponentType, out_diagnostics: ?**IBlob) callconv(mcall) Result,
    };

    /// Combine multiple component types into a composite. The entry points of
    /// the composite are the union of those in `component_types`.
    pub fn createCompositeComponentType(
        self: *ISession,
        component_types: []const *IComponentType,
        out_composite: **IComponentType,
        out_diagnostics: ?**IBlob,
    ) !void {
        const vtable: *const VTable = @ptrCast(self.vtable);
        try vtable.createCompositeComponentType(
            self,
            component_types.ptr,
            @intCast(component_types.len),
            out_composite,
            getDiagnosticsPtr(out_diagnostics),
        ).check();
    }

    /// Load a module from source code.
    pub fn loadModuleFromSource(
        self: *ISession,
        module_name: [*:0]const u8,
        path: [*:0]const u8,
        source: [:0]const u8,
        out_diagnostics: ?**IBlob,
    ) ?*IModule {
        const diagnostics = getDiagnosticsPtr(out_diagnostics);
        defer logDiagnostics(diagnostics, out_diagnostics);
        const module = cdef.slang_loadModuleFromSource(self, module_name, path, source.ptr, source.len, diagnostics) orelse return null;
        module.addRef();
        return module;
    }
};

pub const IModule = extern struct {
    vtable: *const VTable,

    pub const addRef = IUnknown.Mixin(@This()).addRef;
    pub const release = IUnknown.Mixin(@This()).release;

    /// Link the module into a program (its global parameters can then be
    /// reflected on).
    pub const link = IComponentType.Mixin(@This()).link;
    pub const findEntryPointByName = IModule.Mixin(@This()).findEntryPointByName;

    const VTable = extern struct {
        base: IComponentType.VTable,
        findEntryPointByName: *const fn (this: *IModule, name: [*:0]const u8, out_entry_point: **IComponentType) callconv(mcall) Result,
    };

    fn Mixin(comptime T: type) type {
        return struct {
            /// Find an entry point by name. The function must be explicitly
            /// designated as an entry point (e.g. with `[shader("...")]`).
            pub fn findEntryPointByName(self: *T, name: [*:0]const u8) !*IComponentType {
                const vtable: *const VTable = @ptrCast(self.vtable);
                var entry_point: *IComponentType = undefined;
                try vtable.findEntryPointByName(@ptrCast(self), name, &entry_point).check();
                return entry_point;
            }
        };
    }
};

pub const IComponentType = extern struct {
    vtable: *const VTable,

    pub const release = IUnknown.Mixin(@This()).release;
    pub const getLayout = IComponentType.Mixin(@This()).getLayout;
    pub const link = IComponentType.Mixin(@This()).link;
    pub const getEntryPointCode = IComponentType.Mixin(@This()).getEntryPointCode;
    pub const getTargetCode = IComponentType.Mixin(@This()).getTargetCode;

    const VTable = extern struct {
        base: IUnknown.VTable,
        getSession: *const anyopaque,
        getLayout: *const fn (this: *IComponentType, target_index: i64, out_diagnostics: ?**IBlob) callconv(mcall) ?*ProgramLayout,
        getSpecializationParamCount: *const anyopaque,
        getEntryPointCode: *const fn (this: *IComponentType, entry_point_index: i64, target_index: i64, out_code: **IBlob, out_diagnostics: ?**IBlob) callconv(mcall) Result,
        getResultAsFileSystem: *const anyopaque,
        getEntryPointHash: *const anyopaque,
        specialize: *const anyopaque,
        link: *const fn (this: *IComponentType, out_linked: **IComponentType, out_diagnostics: ?**IBlob) callconv(mcall) Result,
        // The following slots must stay in sync with slang.h's IComponentType;
        // the ones we don't use are left opaque.
        getEntryPointHostCallable: *const anyopaque,
        renameEntryPoint: *const anyopaque,
        linkWithOptions: *const anyopaque,
        getTargetCode: *const fn (this: *IComponentType, target_index: i64, out_code: **IBlob, out_diagnostics: ?**IBlob) callconv(mcall) Result,
        getTargetMetadata: *const anyopaque,
        getEntryPointMetadata: *const anyopaque,
    };

    fn Mixin(comptime T: type) type {
        return struct {
            pub fn getLayout(self: *T, target_index: i64, out_diagnostics: ?**IBlob) ?*ProgramLayout {
                const vtable: *const VTable = @ptrCast(self.vtable);
                return vtable.getLayout(@ptrCast(self), target_index, getDiagnosticsPtr(out_diagnostics));
            }

            pub fn link(self: *T, out_diagnostics: ?**IBlob) !*IComponentType {
                const vtable: *const VTable = @ptrCast(self.vtable);
                var linked: *IComponentType = undefined;
                try vtable.link(@ptrCast(self), &linked, getDiagnosticsPtr(out_diagnostics)).check();
                return linked;
            }

            /// Get the compiled code for the entry point at the given index
            /// for the chosen target. For source targets (e.g. GLSL) this is
            /// the generated source code.
            pub fn getEntryPointCode(
                self: *T,
                entry_point_index: i64,
                target_index: i64,
                out_code: **IBlob,
                out_diagnostics: ?**IBlob,
            ) !void {
                const vtable: *const VTable = @ptrCast(self.vtable);
                try vtable.getEntryPointCode(@ptrCast(self), entry_point_index, target_index, out_code, getDiagnosticsPtr(out_diagnostics)).check();
            }

            /// Get the compiled code for the whole program for the chosen
            /// target. For source targets (e.g. Metal) this is the generated
            /// source code.
            pub fn getTargetCode(self: *T, target_index: i64, out_code: **IBlob, out_diagnostics: ?**IBlob) !void {
                const vtable: *const VTable = @ptrCast(self.vtable);
                try vtable.getTargetCode(@ptrCast(self), target_index, out_code, getDiagnosticsPtr(out_diagnostics)).check();
            }
        };
    }
};

pub const ProgramLayout = ShaderReflection;

pub const ShaderReflection = opaque {
    pub const getParameterCount = cdef.spReflection_GetParameterCount;
    pub const getParameterByIndex = cdef.spReflection_GetParameterByIndex;
};

pub const VariableLayoutReflection = opaque {
    pub fn getName(self: *VariableLayoutReflection) [*:0]const u8 {
        return cdef.spReflectionVariable_GetName(cdef.spReflectionVariableLayout_GetVariable(self));
    }

    pub fn getType(self: *VariableLayoutReflection) *TypeReflection {
        return cdef.spReflectionTypeLayout_GetType(cdef.spReflectionVariableLayout_GetTypeLayout(self));
    }

    pub fn getCategoryCount(self: *VariableLayoutReflection) u32 {
        return cdef.spReflectionTypeLayout_GetCategoryCount(cdef.spReflectionVariableLayout_GetTypeLayout(self));
    }

    pub fn getCategoryByIndex(self: *VariableLayoutReflection, index: u32) ParameterCategory {
        return cdef.spReflectionTypeLayout_GetCategoryByIndex(cdef.spReflectionVariableLayout_GetTypeLayout(self), index);
    }
    pub const getOffset = cdef.spReflectionVariableLayout_GetOffset;
    pub const getBindingIndex = cdef.spReflectionParameter_GetBindingIndex;
};

pub const TypeReflection = opaque {
    pub const getKind = cdef.spReflectionType_GetKind;
    pub const getResourceShape = cdef.spReflectionType_GetResourceShape;
};

pub const TypeKind = enum(u32) {
    none = 0,
    constant_buffer = 6,
    resource = 7,
    shader_storage_buffer = 10,
    _,
};

pub const ParameterCategory = enum(u32) {
    none = 0,
    mixed = 1,
    constant_buffer = 2,
    shader_resource = 3,
    unordered_access = 4,
    varying_input = 5,
    varying_output = 6,
    sampler_state = 7,
    uniform = 8,
    descriptor_table_slot = 9,
    _,
};

pub const ResourceShape = packed struct(u32) {
    pub const Base = enum(u4) {
        none = 0x0,
        texture_1d = 0x1,
        texture_2d = 0x2,
        texture_3d = 0x3,
        texture_cube = 0x4,
        texture_buffer = 0x5,
        structured_buffer = 0x6,
        byte_address_buffer = 0x7,
        resource_unknown = 0x8,
        acceleration_structure = 0x9,
        texture_subpass = 0xa,
        _,
    };

    base: Base,
    feedback: bool = false,
    shadow: bool = false,
    array: bool = false,
    multisample: bool = false,
    combined: bool = false,
    _pad: u23 = 0,
};

const cdef = struct {
    extern fn slang_createGlobalSession2(desc: *const GlobalSessionDesc, out_global_session: **IGlobalSession) Result;
    extern fn slang_loadModuleFromSource(session: *ISession, module_name: [*:0]const u8, path: [*:0]const u8, source: [*:0]const u8, source_size: usize, out_diagnostics: ?**IBlob) ?*IModule;

    extern fn spReflection_GetParameterCount(self: *ShaderReflection) u32;
    extern fn spReflection_GetParameterByIndex(self: *ShaderReflection, index: u32) *VariableLayoutReflection;

    extern fn spReflectionVariableLayout_GetVariable(self: *VariableLayoutReflection) *VariableReflection;
    extern fn spReflectionVariable_GetName(self: *VariableReflection) [*:0]const u8;
    extern fn spReflectionTypeLayout_GetCategoryCount(self: *TypeLayoutReflection) u32;
    extern fn spReflectionTypeLayout_GetCategoryByIndex(self: *TypeLayoutReflection, index: u32) ParameterCategory;

    extern fn spReflectionVariableLayout_GetName(self: *VariableLayoutReflection) [*:0]const u8;
    extern fn spReflectionVariableLayout_GetCategoryCount(self: *VariableLayoutReflection) u32;
    extern fn spReflectionVariableLayout_GetCategoryByIndex(self: *VariableLayoutReflection, index: u32) ParameterCategory;
    extern fn spReflectionVariableLayout_GetOffset(self: *VariableLayoutReflection, category: ParameterCategory) usize;
    extern fn spReflectionVariableLayout_GetTypeLayout(self: *VariableLayoutReflection) *TypeLayoutReflection;
    extern fn spReflectionParameter_GetBindingIndex(self: *VariableLayoutReflection) i64;

    extern fn spReflectionType_GetKind(self: *TypeReflection) TypeKind;
    extern fn spReflectionType_GetResourceShape(self: *TypeReflection) ResourceShape;

    // Slang's `IComponentType::getLayout` returns a
    // `slang::ProgramLayout*`, which is a `ShaderReflection`.
    extern fn spReflectionTypeLayout_GetType(self: *TypeLayoutReflection) *TypeReflection;

    pub const TypeLayoutReflection = opaque {};
    pub const VariableReflection = opaque {};
};
