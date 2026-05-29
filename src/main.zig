const std = @import("std");
const lib = @import("jsonl_viewer");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        try std.io.getStdErr().writer().print("usage: {s} <file.jsonl>\n", .{args[0]});
        std.process.exit(64);
    }

    const path = args[1];
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const metadata = try lib.readMetadata(file);
    try std.io.getStdOut().writer().print("path: {s}\nsize: {d} bytes\n", .{ path, metadata.size });
}
