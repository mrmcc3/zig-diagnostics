const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Self = @This();

ally: Allocator,
in_buffer: std.io.BufferedReader(4096, File.Reader),
out_buffer: std.io.BufferedWriter(4096, File.Writer),
header_part: std.ArrayList(u8),
headers: std.http.Headers,
content_part: std.ArrayList(u8),

pub fn init(ally: Allocator, in: File, out: File) Self {
    return .{
        .ally = ally,
        .in_buffer = std.io.bufferedReader(in.reader()),
        .out_buffer = std.io.bufferedWriter(out.writer()),
        .header_part = std.ArrayList(u8).init(ally),
        .headers = std.http.Headers.init(ally),
        .content_part = std.ArrayList(u8).init(ally),
    };
}

pub fn deinit(self: *Self) void {
    self.header_part.deinit();
    self.headers.deinit();
    self.content_part.deinit();
    self.* = undefined;
}

pub fn read(self: *Self) ![]u8 {
    // read header part
    self.header_part.shrinkRetainingCapacity(0);
    var break_state: u2 = 0;
    var reader = self.in_buffer.reader();
    while (true) {
        if (self.header_part.items.len == 4096) return error.header_part_too_long;
        var byte = try reader.readByte();
        switch (break_state) {
            0 => break_state = if (byte == '\r') 1 else 0,
            1 => break_state = if (byte == '\n') 2 else 0,
            2 => break_state = if (byte == '\r') 3 else 0,
            3 => if (byte == '\n') {
                self.header_part.shrinkRetainingCapacity(self.header_part.items.len - 3);
                break;
            },
        }
        try self.header_part.append(byte);
    }

    // parse headers
    self.headers.clearRetainingCapacity();
    var it = std.mem.split(u8, self.header_part.items, "\r\n");
    while (it.next()) |line| {
        var line_it = std.mem.split(u8, line, ": ");
        const header_name = line_it.next() orelse return error.invalid_header;
        const header_value = line_it.next() orelse return error.invalid_header;
        try self.headers.append(header_name, header_value);
    }
    const len = self.headers.getFirstValue("Content-Length") orelse return error.no_content_length;
    const content_length = try std.fmt.parseInt(u32, len, 10);

    // read content part
    try self.content_part.resize(content_length);
    const bytes_read = try reader.readAll(self.content_part.items);
    if (bytes_read < self.content_part.items.len) return error.partial_content;
    return self.content_part.items;
}

pub fn write(self: *Self, msg: []const u8) !void {
    var writer = self.out_buffer.writer();
    try writer.print("Content-Length: {}\r\n\r\n", .{msg.len});
    try writer.writeAll(msg);
    try self.out_buffer.flush();
}

test "io #1" {
    const ally = std.testing.allocator;
    const cwd = std.fs.cwd();
    {
        var file = try cwd.createFile("/tmp/zighx-test-1", .{ .read = true });
        defer file.close();
        var lsp = Self.init(ally, file, file);
        defer lsp.deinit();

        try lsp.write("hello");
        try lsp.write("world!");
    }
    {
        var file = try cwd.openFile("/tmp/zighx-test-1", .{ .mode = .read_only });
        defer file.close();
        var lsp = Self.init(ally, file, file);
        defer lsp.deinit();

        try std.testing.expectEqualStrings("hello", try lsp.read());
        try std.testing.expectEqualStrings("world!", try lsp.read());
        try std.testing.expectError(error.EndOfStream, lsp.read());
    }
}
