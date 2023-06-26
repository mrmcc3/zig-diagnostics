state: State,
writer: std.ArrayList(u8).Writer,
allocator: std.mem.Allocator,

const std = @import("std");
const Message = @import("./message.zig").Message;
const Self = @This();

const State = enum {
    not_initialized,
    initializing,
    initialized,
    shutting_down,
};

pub fn init(writer: std.ArrayList(u8).Writer, allocator: std.mem.Allocator) Self {
    return .{
        .state = .not_initialized,
        .writer = writer,
        .allocator = allocator,
    };
}

pub fn err(self: Self, code: i32, message: []const u8) !void {
    var json = std.json.writeStream(self.writer, 10);
    json.whitespace = .{ .indent = .none, .separator = false };
    try json.beginObject();
    try json.objectField("id");
    try json.emitNull();
    try json.objectField("error");
    try json.beginObject();
    try json.objectField("code");
    try json.emitNumber(code);
    try json.objectField("message");
    try json.emitString(message);
    try json.endObject();
    try json.endObject();
}

pub fn process(self: *Self, val: std.json.Value) !void {
    switch (val) {
        .array => |arr| {
            if (arr.items.len == 0) {
                try self.err(-32600, "invalid request");
            } else {
                for (arr.items) |v| try self.process_obj(v);
            }
        },
        else => try self.process_obj(val),
    }
}

pub fn parse_ast(self: Self, uri: []const u8, text: []const u8) !void {
    const source = try self.allocator.dupeZ(u8, text);
    defer self.allocator.free(source);
    var tree = try std.zig.Ast.parse(self.allocator, source, .zig);
    defer tree.deinit(self.allocator);
    var json = std.json.writeStream(self.writer, 10);
    json.whitespace = .{ .indent = .none, .separator = false };
    try json.beginObject();
    try json.objectField("method");
    try json.emitString("textDocument/publishDiagnostics");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("uri");
    try json.emitString(uri);
    try json.objectField("diagnostics");
    try json.beginArray();
    var msg = std.ArrayList(u8).init(self.allocator);
    defer msg.deinit();
    for (tree.errors) |e| {
        msg.clearRetainingCapacity();
        try json.arrayElem();
        try json.beginObject();
        try json.objectField("severity");
        try json.emitNumber(1);
        try tree.renderError(e, msg.writer());
        try json.objectField("message");
        try json.emitString(msg.items);
        const loc = tree.tokenLocation(0, e.token);
        const tok = tree.tokenSlice(e.token);
        try json.objectField("range");
        try json.beginObject();
        try json.objectField("start");
        try json.beginObject();
        try json.objectField("line");
        try json.emitNumber(loc.line);
        try json.objectField("character");
        try json.emitNumber(loc.column);
        try json.endObject();
        try json.objectField("end");
        try json.beginObject();
        try json.objectField("line");
        try json.emitNumber(loc.line);
        try json.objectField("character");
        try json.emitNumber(loc.column + tok.len);
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try json.endObject();
}

pub fn process_obj(self: *Self, val: std.json.Value) !void {
    var message = Message.parse(val) catch |e| {
        std.debug.print("{any}\n", .{e});
        switch (e) {
            error.message_invalid => try self.err(-32600, "invalid request"),
            error.response_invalid,
            error.response_unknown,
            error.notification_unknown,
            error.notification_invalid,
            => {},
        }
        return;
    };

    // TODO
    // - save open a child process to `zig fmt --stdin --ast-check --check`
    // - parse errors from stderr and send back as diagnostics

    switch (message) {
        .initialize => |initialize| {
            switch (self.state) {
                .not_initialized => {
                    self.state = .initializing;
                    try initialize.respond(self.writer);
                },
                .initializing, .initialized => try self.err(-32803, "initialize can only be sent once"),
                .shutting_down => try self.err(-32803, "server is shutting down"),
            }
        },
        .initialized => {
            switch (self.state) {
                .initializing => self.state = .initialized,
                else => return,
            }
        },
        // .document_did_save,
        .document_did_open => |n| {
            switch (self.state) {
                .initialized => try self.parse_ast(n.uri, n.text),
                else => return,
            }
        },
        .document_did_change => |n| {
            switch (self.state) {
                .initialized => try self.parse_ast(n.uri, n.text),
                else => return,
            }
        },
        .document_did_close => return,
        .shutdown => |shutdown| {
            switch (self.state) {
                .initialized => {
                    self.state = .shutting_down;
                    try shutdown.respond(self.writer);
                },
                .not_initialized, .initializing => try self.err(-32002, "server not initialized"),
                .shutting_down => try self.err(-32803, "server is already shutting down"),
            }
        },
        .exit => {
            switch (self.state) {
                .shutting_down => return error.exit,
                else => return error.premature_exit,
            }
        },
        else => {},
    }
}
