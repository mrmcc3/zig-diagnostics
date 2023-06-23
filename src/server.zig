state: State,
writer: std.ArrayList(u8).Writer,

const std = @import("std");
const Message = @import("./message.zig").Message;
const Self = @This();

const State = enum {
    not_initialized,
    initializing,
    initialized,
    shutting_down,
};

pub fn init(writer: std.ArrayList(u8).Writer) Self {
    return .{ .state = .not_initialized, .writer = writer };
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

pub fn process_obj(self: *Self, val: std.json.Value) !void {
    var message = Message.parse(val) catch |e| {
        std.debug.print("\n{any}\n", .{e});
        switch (e) {
            error.message_invalid => try self.err(-32600, "invalid request"),
            error.response_invalid,
            error.response_unknown,
            error.notification_unknown,
            => {},
        }
        return;
    };

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
        .shutdown => |shutdown| {
            switch (self.state) {
                .initialized => {
                    self.state = .shutting_down;
                    try shutdown.respond(self.writer);
                },
                .not_initialized,
                .initializing,
                => try self.err(-32002, "server not initialized"),
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
