//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const builtin = @import("builtin");

const sys_alloc = if (builtin.link_libc == true) std.heap.c_allocator else std.heap.page_allocator;
const AllocationError = std.mem.Allocator.Error;

const File = std.fs.File;
const Dir = std.fs.Dir;

pub fn main() !void {
    {
        var a_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var args = try std.process.argsWithAllocator(a_alloc.allocator());
        defer a_alloc.deinit();
        _ = args.skip(); //skip 1st value (current program name)

        var next = args.next();
        if (next == null) try handle_dir(std.fs.cwd()) else while (next) |arg| : (next = args.next()) handle_dir(arg) catch |err| {
            try errIfInSet(AllocationError, err);
            continue;
        };
    }
}

const file_hash_set = @import("file_hash_set.zig");
const FileHashSet = file_hash_set.FileHashSet;

const log = std.log;

const GetFdPathSupported = std.os.isGetFdPathSupportedOnTarget(builtin.target.os);
fn handle_dir(dir_in: anytype) !void {
    const T = @TypeOf(dir_in);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_str: []const u8 = path_buf[0..0];

    if (T == [:0]const u8) {
        @memcpy(path_buf[0..dir_in.len], dir_in);
        path_str = path_buf[0..dir_in.len];
    }

    const cwd = std.fs.cwd();
    path_str = (if (T == Dir) (if (GetFdPathSupported) std.os.getFdPath(dir_in.fd, &path_buf) else dir_in.realpath(".", &path_buf)) else cwd.realpath(dir_in, &path_buf)) catch |err| {
        logPathedError(path_str, err);
        return err;
    };

    const dir: Dir = (if (T == [:0]const u8) cwd.openDir(dir_in, .{ .iterate = true }) else if (T == Dir) dir_in.openDir(".", .{ .iterate = true }) else @compileError("input type not supported")) catch |err|
        {
            logPathedError(path_str, err);
            return err;
        };

    var unique_files = FileHashSet.empty;
    defer unique_files.deinit(sys_alloc);

    var entries = dir.iterateAssumeFirstIteration();
    const error_handler = struct {
        fn error_handler(iter: *Dir.Iterator, scope: @TypeOf(path_str)) ?Dir.Entry {
            return iter.next() catch |err| {
                logPathedError(scope, err);
                return error_handler(iter, scope); //@call(.always_tail, error_handler, .{iter}); // as of 0.14.0: unclear LLVM error
            };
        }
    }.error_handler;
    while (error_handler(&entries, path_str)) |entry| {
        if (entry.kind != .file) continue;

        path_buf[path_str.len] = std.fs.path.sep;
        path_str.len += 1;
        @memcpy(path_buf[path_str.len..][0..entry.name.len], entry.name);
        path_str.len += entry.name.len;
        defer path_str.len -= 1 + entry.name.len;

        handleFile(dir, path_str, &unique_files) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => |e| logPathedError(path_str, e),
        };
    }
}
const is_windows = builtin.target.os.tag == .windows;

fn handleFile(dir: Dir, path: []const u8, unique_files: *FileHashSet) !void {
    const file = try dir.openFile(path, .{ .mode = .read_only, .lock = .exclusive, .lock_nonblocking = true });
    errdefer file.close();

    const size = (try file.stat()).size;
    const unique = try unique_files.getOrPut(sys_alloc, .{ .file = file, .size = size });
    if (unique.found_existing) {
        @branchHint(.unpredictable);
        if (is_windows) file.close();
        defer if (!is_windows) file.close();
        dir.deleteFile(path) catch |err| logPathedError(path, err);
    } else {
        const result = file.downgradeLock();
        unique.key_ptr.file = file;
        unique.key_ptr.size = size;
        result catch |err| switch (err) {
            error.FileLocksNotSupported => {},
            else => |e| logPathedError(path, e),
        };
    }
}

fn logPathedError(path: []const u8, err: anytype) void {
    log.err("{s}: {}", .{ path, err });
}

fn errIfInSet(err_set: type, err: anytype) err_set!void {
    for (@typeInfo(err_set).error_set.?) |err_info|
        if (std.mem.eql(u8, @errorName(err), err_info.name))
            return @errorCast(err);
}
