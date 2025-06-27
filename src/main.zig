//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const builtin = @import("builtin");

const sys_alloc = if (builtin.link_libc == true) std.heap.c_allocator else std.heap.page_allocator;
const AllocationError = std.mem.Allocator.Error;

const File = std.fs.File;
const Dir = std.fs.Dir;

var cwd: Dir = undefined;
pub fn main() !void {
    {
        var a_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var args = try std.process.argsWithAllocator(a_alloc.allocator());
        defer a_alloc.deinit();
        _ = args.skip(); //skip 1st value (current program name)

        cwd = std.fs.cwd();

        var next = args.next();
        if (next == null)
            try handleDir(".")
        else while (next) |arg| : (next = args.next())
            handleDir(arg) catch |err| {
                try errIfInSet(AllocationError, err);
                continue;
            };
    }
}

const file_hash_set = @import("file_hash_set.zig");
const FileHashSet = file_hash_set.FileHashSet;

const log = std.log;

fn handleDir(dir_in: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes - 1]u8 = undefined;
    @memcpy(path_buf[0..dir_in.len], dir_in);
    var path_str: []const u8 = path_buf[0..dir_in.len];

    var dir: Dir = cwd.openDir(path_str, .{ .iterate = true }) catch |err| {
        logPathedError(path_str, err);
        return err;
    };
    defer dir.close();

    var unique_files = FileHashSet.empty;
    defer {
        var iter = unique_files.keyIterator();
        while (iter.next()) |key| key.file.close();
        unique_files.deinit(sys_alloc);
    }

    var entries = dir.iterateAssumeFirstIteration();
    while (nextSkipErrors(Dir.Entry, &entries, path_str)) |entry| {
        if (entry.kind != .file) continue;

        path_buf[path_str.len] = std.fs.path.sep;
        path_str.len += 1;
        @memcpy(path_buf[path_str.len..][0..entry.name.len], entry.name);
        path_str.len += entry.name.len;
        defer path_str.len -= 1 + entry.name.len;

        handleFile(path_str, &unique_files) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => |e| logPathedError(path_str, e),
        };
    }
}
const is_windows = builtin.target.os.tag == .windows;

fn handleFile(path: []const u8, unique_files: *FileHashSet) !void {
    const file = try cwd.openFile(path, .{ .mode = .read_only, .lock = .exclusive, .lock_nonblocking = true });
    errdefer file.close();

    const size = (try file.stat()).size;
    const unique = try unique_files.getOrPutAdapted(sys_alloc, file_hash_set.FileKey{ .file = file, .size = size }, file_hash_set.NewFileContext{});
    if (unique.found_existing) {
        @branchHint(.unpredictable);
        if (is_windows) file.close();
        defer if (!is_windows) file.close();
        cwd.deleteFile(path) catch |err| logPathedError(path, err);
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

fn nextSkipErrors(return_type: type, iter: anytype, scope: []const u8) ?return_type {
    while (true)
        if (iter.next()) |optional|
            return optional
        else |err|
            logPathedError(scope, err);
}

fn logPathedError(path: []const u8, err: anytype) void {
    log.err("{s}: {}", .{ path, err });
}

fn errIfInSet(err_set: type, err: anytype) err_set!void {
    for (@typeInfo(err_set).error_set.?) |err_info|
        if (std.mem.eql(u8, @errorName(err), err_info.name))
            return @errorCast(err);
}
