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

const max_file_size = @import("constants.zig").max_file_size;

const GetFdPathSupported = std.os.isGetFdPathSupportedOnTarget(builtin.target.os);
fn handle_dir(dir_in: anytype) !void {
    const T = @TypeOf(dir_in);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_str: []const u8 = path_buf[0..0];

    if (T == [:0]const u8) {
        @memcpy(&path_buf, dir_in);
        path_str = path_buf[0..dir_in.len];
    }

    const log = std.log;
    path_str = (if (T == Dir) (if (GetFdPathSupported) std.os.getFdPath(dir_in.fd, &path_buf) else dir_in.realpath(".", &path_buf)) else cwd.realpath(dir_in, &path_buf)) catch |err| {
        log.err("{s}: {}", .{ path_str, err });
        return err;
    };

    const dir: Dir = (if (T == [:0]const u8) cwd.openDir(dir_in, .{ .iterate = true }) else if (T == Dir) dir_in.openDir(".", .{ .iterate = true }) else @compileError("input type not supported")) catch |err|
        {
            std.log.err("{s}: {}", .{ path_str, err });
            return err;
        };

    var duplicates = std.ArrayListUnmanaged(File).empty;
    defer {
        log.info("{s}: deleted: {d}", .{ path_str, duplicates.items.len });
        duplicates.deinit(sys_alloc);
    }

    var unique_files = std.StringHashMapUnmanaged(void).empty;
    defer unique_files.deinit(sys_alloc);

    var f_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer f_alloc.deinit();

    var entries = dir.iterateAssumeFirstIteration();
    const error_handler = struct {
        fn error_handler(iter: *Dir.Iterator, scope: @TypeOf(path_str)) ?Dir.Entry {
            return iter.next() catch |err| {
                log.err("{s}: {}", .{ scope, err });
                return error_handler(iter, scope); //@call(.always_tail, error_handler, .{iter}); // as of 0.14.0: unclear LLVM error
            };
        }
    }.error_handler;
    while (error_handler(&entries, path_str)) |entry| {
        if (entry.kind != .file) continue;

        path_buf[path_str.len] = std.fs.path.sep;
        path_str.len += 1;
        @memcpy(path_buf[path_str.len..entry.name.len], entry.name);
        path_str.len += entry.name.len;
        defer path_str.len -= 1 + entry.name.len;

        const new_file = dir.openFile(entry.name, .{}) catch |err| {
            log.err("{s}: {}", .{ path_str, err });
            continue;
        };

        var new_size = if (new_file.stat()) |stat| stat.size else |err| err: {
            log.err("{s}: {}", .{ path_str, err });
            break :err null;
        };
        const new_data = new_file.readToEndAllocOptions(f_alloc.allocator(), max_file_size, new_size, 1, null) catch |err| {
            try errIfInSet(AllocationError, err);
            log.err("{s}: {}", .{ path_str, err });
            continue;
        };
        defer _ = f_alloc.reset(.retain_capacity);

        new_size = new_data.len;

        const unique = try unique_files.getOrPut(sys_alloc, new_data);
        if (unique.found_existing)
            try duplicates.append(sys_alloc, new_file);
    }
}

fn data_eql(a: []const u8, b: []const u8) bool {
    for (a, b) |a_c, b_c| {
        if (a_c != b_c) return false;
    }
    return true;
}
fn errIfInSet(err_set: type, err: anytype) err_set!void {
    for (@typeInfo(err_set).error_set.?) |err_info| if (std.mem.eql(u8, @errorName(err), err_info.name)) return @errorCast(err);
}
