const std = @import("std");
const builtin = @import("builtin");

const hash_map = std.hash_map;
const HashMap = hash_map.HashMapUnmanaged;
const Hasher = std.hash.Wyhash;
const seed = 0;

const File = std.fs.File;

/// File handles in the keys need to be closed manually.
pub const FileHashSet = HashMap(FileKey, void, FileContext, hash_map.default_max_load_percentage);

const buflen = std.heap.page_size_min;
const BufType = [buflen]u8;

pub const FileContext = struct {
    const Self = @This();

    pub fn hash(self: Self, key: anytype) u64 {
        _ = self;
        const Key = @TypeOf(key);
        const has_hash_field = @hasField(Key, "hash");

        var hasher = Hasher.init(seed);
        var buffer: BufType = undefined;

        var total_rd: FileSize = 0;

        if (has_hash_field and key.hash != null) return key.hash;
        if (@hasField(Key, "hash_lock"))
            key.hash_lock.lock()
        else
            key.file.seekTo(0) catch |err| fatalError(err);

        while (true) {
            const rd_len = key.file.readAll(&buffer) catch |err| fatalError(err);
            hasher.update(buffer[0..rd_len]);
            total_rd += rd_len;
            if (rd_len < buflen) break;
        }
        if (@typeInfo(@FieldType(Key, "size")) == .optional) key.size = key.size orelse total_rd;

        const final_hash = hasher.final();
        if (has_hash_field) key.hash = final_hash;
        return final_hash;
    }
    pub fn eql(self: Self, a: anytype, b: FileKey) bool {
        _ = self;
        const size: FileSize = if (@typeInfo(@FieldType(@TypeOf(a), "size")) == .optional) a.size orelse b.size else a.size;
        if (size != b.size) return false;

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

pub const FileHash = @typeInfo(@FieldType(Hasher, "final")).@"fn".return_type.?;
pub const FileSize = @FieldType(File.Stat, "size");
/// Assumes the reader has been used before.
/// Resets the reader before all operations.
pub const FileKey = struct {
    file: File,
    size: FileSize,
};
/// Asumes the reader has not been used before.
/// Does not reset the reader before hashing.
pub const NewFileKey = struct {
    file: File,
    size: ?FileSize,

    hash_lock: std.debug.SafetyLock = .{},
};
/// `FileKey` with precomputed hash.
///
/// Assumes the reader has been used before.
/// Resets the reader before all operations.
pub const HashedFileKey = struct {
    file: File,
    size: FileSize,
    hash: FileHash,

    /// Hashes the file, and stores it in a HashedFileKey.
    ///
    /// Size can be acquired for minimal cost while hashing.
    pub fn fromFileKey(key: anytype) HashedFileKey {
        const hash = FileContext.hash(key);

        const ret = HashedFileKey{ .file = key.file, .size = key.size, .hash = hash };

        return ret;
    }
};
