const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;
const cli = @import("../cli.zig");

pub const Options = struct {
    /// The path of the config file to validate. If this isn't specified,
    /// then the default config file paths will be validated.
    @"config-file": ?[:0]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `validate-config` command is used to validate a Ghostty config file.
///
/// When executed without any arguments, this will load the config from the default
/// location.
///
/// Flags:
///
///   * `--config-file`: can be passed to validate a specific target config file in
///     a non-default location
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    const result = runInner(alloc, opts, stdout);
    stdout.flush() catch {};
    return result;
}

fn runInner(
    alloc: std.mem.Allocator,
    opts: Options,
    stdout: *std.Io.Writer,
) !u8 {
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    // If a config path is passed, validate it, otherwise validate default configs
    if (opts.@"config-file") |config_path| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = try std.fs.cwd().realpath(config_path, &buf);
        try cfg.loadFile(alloc, abs_path);
        try cfg.loadRecursiveFiles(alloc);
    } else {
        cfg = try Config.load(alloc);
    }

    try cfg.finalize();

    if (cfg._diagnostics.items().len > 0) {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        defer stream.deinit();

        for (cfg._diagnostics.items()) |diag| {
            try diag.write(&stream.writer);
            try stdout.print("{s}\n", .{stream.written()});
            stream.clearRetainingCapacity();
        }

        return 1;
    }

    return 0;
}
