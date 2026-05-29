const std = @import("std");

pub const jsonl_reader = @import("jsonl_reader.zig");

pub const Metadata = struct {
    size: u64,
};

pub fn readMetadata(file: std.fs.File) !Metadata {
    const stat = try file.stat();
    return .{ .size = stat.size };
}

test "readMetadata returns file size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("sample.jsonl", .{});
    defer file.close();

    try file.writeAll("{\"a\":1}\n");

    const metadata = try readMetadata(file);
    try std.testing.expectEqual(@as(u64, 8), metadata.size);
}

test {
    std.testing.refAllDecls(@This());
}
