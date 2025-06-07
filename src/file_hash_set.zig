const std = @import("std");

const hash_map = std.hash_map;
const HashMap = hash_map.HashMapUnmanaged;
const Hasher = std.hash.Wyhash;
const seed = 0;

pub const FileHashSet = HashMap(FileKey, void, FileContext, hash_map.default_max_load_percentage);

const buflen = std.heap.page_size_min;
const BufType = [buflen]u8;

pub const FileContext = struct {
    const Self = @This();
    pub fn hash(self: Self, a: FileKey) u64 {
        _ = self;
        var hasher = Hasher.init(seed);
        var buffer: BufType = undefined;

        a.file.seekTo(0) catch |err| fatalError(err);
        while (true) {
            const rd_len = a.file.readAll(&buffer) catch |err| fatalError(err);
            hasher.update(buffer[0..rd_len]);
            if (rd_len < buflen) break;
        }
        return hasher.final();
    }
    pub fn eql(self: Self, a: FileKey, b: FileKey) bool {
        _ = self;
        if (a.size != b.size) return false;

        var buf_a: BufType = undefined;
        var buf_b: BufType = undefined;

        a.file.seekTo(0) catch |err| fatalError(err);
        b.file.seekTo(0) catch |err| fatalError(err);
        while (true) {
            const rd_cnt_a = a.file.readAll(&buf_a) catch |err| fatalError(err);
            const rd_cnt_b = b.file.readAll(&buf_b) catch |err| fatalError(err);
            if (rd_cnt_a != rd_cnt_b or !data_eql(buf_a[0..rd_cnt_a], buf_b[0..rd_cnt_b]))
                return false
            else if (rd_cnt_a < buflen)
                break;
        }
        return true;
    }
};

pub const DataFileContext = struct {
    const Self = @This();
    pub fn hash(self: Self, a: []const u8) u64 {
        _ = self;
        return Hasher.hash(seed, a);
    }
    pub fn eql(self: Self, a: []const u8, b: FileKey) bool {
        _ = self;
        if (a.len != b.size) return false;

        var total_rd = 0;
        var buf_b: BufType = undefined;

        b.file.seekTo(0) catch |err| fatalError(err);
        while (true) {
            const rd_cnt = b.file.readAll(&buf_b) catch |err| fatalError(err);
            if (!data_eql(a[total_rd..rd_cnt], buf_b[0..rd_cnt])) return false;
            total_rd += rd_cnt;

            if (total_rd > a.len)
                return false
            else if (rd_cnt < buflen) break;
        }
        return true;
    }
};

fn data_eql(a: []const u8, b: []const u8) bool {
    for (a, b) |a_c, b_c| {
        if (a_c != b_c) return false;
    }
    return true;
}

fn fatalError(err: anytype) noreturn {
    const Type = @TypeOf(err);
    switch (@typeInfo(Type)) {
        .error_set => std.process.fatal("{}", .{err}),
        else => @compileError("expected error but found " ++ @typeName(Type) ++ " instead"),
    }
}

pub const FileSize = @FieldType(std.fs.File.Stat, "size");
pub const FileKey = struct {
    file: std.fs.File,
    size: FileSize,
};
