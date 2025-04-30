//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const builtin = @import("builtin");

const sys_alloc = if (builtin.link_libc == true) std.heap.c_allocator else std.heap.page_allocator;
const AllocationError = std.mem.Allocator.Error;

const File = std.fs.File;
const Dir = std.fs.Dir;

const cwd = std.fs.cwd();

pub fn main() !void {
    {
        var a_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var args = try std.process.argsWithAllocator(a_alloc.allocator());
        defer a_alloc.deinit();
        _ = args.skip(); //skip 1st value (current program name)

        var next = args.next();
        if (next == null) try handle_dir(cwd) else while (next) |arg| : (next = args.next()) handle_dir(arg) catch |err| {
            try errIfInSet(AllocationError, err);
            continue;
        };
    }
}

fn handle_dir(dir_in: anytype) !void {
    const T = @TypeOf(dir_in);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_str: []const u8 = path_buf[0..1];

    if (T == [:0]const u8) {
        @memcpy(&path_buf, dir_in);
        dir_str = path_buf[0..dir_in.len];
    }

    const log = std.log;
    dir_str = (if (T == Dir) (if (comptime std.os.isGetFdPathSupportedOnTarget(builtin.target.os)) std.os.getFdPath(dir_in.fd, &path_buf) else dir_in.realpath(".", &path_buf)) else cwd.realpath(dir_in, &path_buf)) catch |err| {
        log.err("{s}: {}", .{ dir_str, err });
        return err;
    };

    const dir: Dir = (if (T == [:0]const u8) cwd.openDir(dir_in, .{ .iterate = true }) else if (T == Dir) dir_in.openDir(".", .{ .iterate = true }) else @compileError("input type not supported")) catch |err|
        {
            std.log.err("{s}: {}", .{ dir_str, err });
            return err;
        };

    var duplicates = std.ArrayListAlignedUnmanaged(File, @sizeOf(File)).empty;
    defer duplicates.deinit(sys_alloc);

    var u_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer u_alloc.deinit();

    var unique_files = std.StringHashMapUnmanaged(void).empty;

    var f_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer f_alloc.deinit();

    var deleted: usize = 0;
    defer log.info("deleted: {d}", .{deleted});

    var entries = dir.iterateAssumeFirstIteration();
    const error_handler = struct {
        fn error_handler(iter: *Dir.Iterator) ?Dir.Entry {
            return iter.next() catch |err| {
                log.err("{}", .{err});
                return error_handler(iter); //@call(.always_tail, error_handler, .{iter}); // as of 0.14.0: unclear LLVM error
            };
        }
    }.error_handler;
    while (error_handler(&entries)) |entry| {
        if (entry.kind != .file) continue;
        const new_file = dir.openFile(entry.name, .{}) catch |err| {
            log.err("{s}: {}", .{ entry.name, err });
            continue;
        };
        defer _ = f_alloc.reset(.retain_capacity);

        var new_size = if (new_file.stat()) |stat| stat.size else |err| err: {
            log.err("{}", .{err});
            break :err null;
        };
        const new_data = new_file.readToEndAllocOptions(f_alloc.allocator(), new_size orelse std.math.maxInt(usize), new_size, 1, null) catch |err| {
            try errIfInSet(AllocationError, err);
            log.err("{}", .{err});
            continue;
        };

        new_size = new_data.len;

        const unique = try unique_files.getOrPut(u_alloc.allocator(), new_data);
        if (unique.found_existing) {
            try duplicates.append(sys_alloc, new_file);
            {
                // If there are more files than usize, we'll have run out of memory already
                @setRuntimeSafety(false);
                deleted += 1;
            }
        }
    }
}

const ScopedLog = struct {
    scope: []u8,
};
fn data_eql(a: []const u8, b: []const u8) bool {
    for (a, b) |a_c, b_c| {
        if (a_c != b_c) return false;
    }
    return true;
}
fn errIfInSet(err_set: type, err: anytype) err_set!void {
    for (@typeInfo(err_set).error_set.?) |err_info| if (std.mem.eql(u8, @errorName(err), err_info.name)) return @errorCast(err);
}
