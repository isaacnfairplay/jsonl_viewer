const std = @import("std");

pub const JsonPolicy = enum {
    /// Return each JSONL record as bytes; callers may parse later.
    unchecked,
    /// Parse the line and return error.InvalidJson if it is not one complete JSON value.
    validate,
};

pub const ReadPolicy = struct {
    validate_utf8: bool = true,
    json: JsonPolicy = .unchecked,
};

pub const Error = error{
    EmptyBuffer,
    DestinationTooSmall,
    LineTooLong,
    InvalidUtf8,
    InvalidJson,
};

/// Buffered JSONL reader over a caller-owned reusable buffer.
///
/// `readLineSlice` returns a slice into `buffer`, valid until the next read.
/// Lines returned by that API must fit in the reusable buffer. Use
/// `readLineInto` when a line may span multiple buffer refills.
///
/// By default lines are validated as UTF-8 but not parsed as JSON. Set
/// `policy.json = .validate` to reject malformed JSON early.
pub const JsonlReader = struct {
    file: std.fs.File,
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    pub fn init(file: std.fs.File, buffer: []u8) Error!JsonlReader {
        if (buffer.len == 0) return error.EmptyBuffer;
        return .{ .file = file, .buffer = buffer };
    }

    pub fn readLineSlice(self: *JsonlReader, max_line_len: usize, policy: ReadPolicy) !?[]const u8 {
        while (true) {
            if (self.start == self.end) {
                self.start = 0;
                self.end = 0;
                if (self.eof) return null;
            }

            if (std.mem.indexOfScalar(u8, self.buffer[self.start..self.end], '\n')) |newline| {
                const raw = self.buffer[self.start .. self.start + newline];
                self.start += newline + 1;
                const line = trimCarriageReturn(raw);
                try validateLine(line, max_line_len, policy);
                return line;
            }

            if (self.eof) {
                const raw = self.buffer[self.start..self.end];
                self.start = self.end;
                const line = trimCarriageReturn(raw);
                try validateLine(line, max_line_len, policy);
                return line;
            }

            if (self.end - self.start > max_line_len) return error.LineTooLong;
            if (self.start != 0) {
                const remaining = self.buffer[self.start..self.end];
                std.mem.copyForwards(u8, self.buffer[0..remaining.len], remaining);
                self.start = 0;
                self.end = remaining.len;
            }
            if (self.end == self.buffer.len) return error.LineTooLong;

            const n = try self.file.read(self.buffer[self.end..]);
            if (n == 0) {
                self.eof = true;
            } else {
                self.end += n;
            }
        }
    }

    pub fn readLineInto(self: *JsonlReader, dest: []u8, max_line_len: usize, policy: ReadPolicy) !?[]u8 {
        var used: usize = 0;

        while (true) {
            if (self.start == self.end) {
                self.start = 0;
                self.end = 0;
                if (self.eof) return null;

                const n = try self.file.read(self.buffer);
                if (n == 0) {
                    self.eof = true;
                    if (used == 0) return null;
                    const line = trimCarriageReturn(dest[0..used]);
                    try validateLine(line, max_line_len, policy);
                    return line;
                }
                self.end = n;
            }

            const window = self.buffer[self.start..self.end];
            const take = if (std.mem.indexOfScalar(u8, window, '\n')) |newline| newline else window.len;
            if (used + take > max_line_len) return error.LineTooLong;
            if (used + take > dest.len) return error.DestinationTooSmall;
            @memcpy(dest[used .. used + take], window[0..take]);
            used += take;
            self.start += take;

            if (self.start < self.end and self.buffer[self.start] == '\n') {
                self.start += 1;
                const line = trimCarriageReturn(dest[0..used]);
                try validateLine(line, max_line_len, policy);
                return line;
            }

            if (self.eof) {
                const line = trimCarriageReturn(dest[0..used]);
                try validateLine(line, max_line_len, policy);
                return line;
            }
        }
    }
};

fn trimCarriageReturn(line: anytype) @TypeOf(line) {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn validateLine(line: []const u8, max_line_len: usize, policy: ReadPolicy) Error!void {
    if (line.len > max_line_len) return error.LineTooLong;
    if (policy.validate_utf8 and !std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
    if (policy.json == .validate) validateJson(line) catch return error.InvalidJson;
}

fn validateJson(line: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(std.heap.page_allocator, line);
    defer scanner.deinit();

    while (true) {
        const token = try scanner.next();
        if (token == .end_of_document) break;
    }
}

test "readLineSlice returns reusable-buffer line slices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("slice.jsonl", .{ .read = true });
    defer file.close();
    try file.writeAll("{\"a\":1}\n{\"b\":2}\r\n");
    try file.seekTo(0);

    var buf: [32]u8 = undefined;
    var reader = try JsonlReader.init(file, &buf);

    try std.testing.expectEqualStrings("{\"a\":1}", (try reader.readLineSlice(32, .{})).?);
    try std.testing.expectEqualStrings("{\"b\":2}", (try reader.readLineSlice(32, .{})).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try reader.readLineSlice(32, .{}));
}

test "readLineInto copies a line spanning buffer refills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("copy.jsonl", .{ .read = true });
    defer file.close();
    try file.writeAll("{\"message\":\"hello\"}\n");
    try file.seekTo(0);

    var buf: [5]u8 = undefined;
    var out: [64]u8 = undefined;
    var reader = try JsonlReader.init(file, &buf);

    try std.testing.expectEqualStrings("{\"message\":\"hello\"}", (try reader.readLineInto(&out, out.len, .{})).?);
    try std.testing.expectEqual(@as(?[]u8, null), try reader.readLineInto(&out, out.len, .{}));
}

test "readLineInto enforces bounded destination and max line length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("long.jsonl", .{ .read = true });
    defer file.close();
    try file.writeAll("abcdef\n");
    try file.seekTo(0);

    var buf: [2]u8 = undefined;
    var out: [8]u8 = undefined;
    var reader = try JsonlReader.init(file, &buf);

    try std.testing.expectError(error.LineTooLong, reader.readLineInto(&out, 3, .{}));
}

test "policies reject invalid utf8 and invalid json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("invalid.jsonl", .{ .read = true });
    defer file.close();
    try file.writeAll(&.{ 0xff, '\n' });
    try file.seekTo(0);

    var buf: [16]u8 = undefined;
    var reader = try JsonlReader.init(file, &buf);
    try std.testing.expectError(error.InvalidUtf8, reader.readLineSlice(16, .{}));

    try file.seekTo(0);
    reader = try JsonlReader.init(file, &buf);
    try std.testing.expectEqualStrings(&.{0xff}, (try reader.readLineSlice(16, .{ .validate_utf8 = false })).?);

    var json_file = try tmp.dir.createFile("bad_json.jsonl", .{ .read = true });
    defer json_file.close();
    try json_file.writeAll("{bad json}\n");
    try json_file.seekTo(0);

    reader = try JsonlReader.init(json_file, &buf);
    try std.testing.expectError(error.InvalidJson, reader.readLineSlice(16, .{ .json = .validate }));
}
