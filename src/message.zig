const std = @import("std");

const RequestId = union(enum) {
    string: []const u8,
    integer: i32,

    const Self = @This();

    pub fn parse(val: std.json.Value) !?Self {
        switch (val) {
            .string => |s| return .{ .string = s },
            .integer => |i| {
                if (i < std.math.minInt(i32)) return error.message_invalid;
                if (i > std.math.maxInt(i32)) return error.message_invalid;
                return .{ .integer = @intCast(i32, i) };
            },
            .null => return null,
            else => return error.message_invalid,
        }
    }
};

pub const Message = union(enum) {
    initialize: InitializeRequest,
    initialized: void,
    shutdown: ShutdownRequest,
    exit: void,

    request_invalid: RequestError,
    request_unknown: RequestError,

    const Self = @This();

    pub fn parse(val: std.json.Value) !Self {
        var obj = switch (val) {
            .object => |o| o,
            else => return error.message_invalid,
        };
        const rpc = obj.get("jsonrpc") orelse return error.message_invalid;
        switch (rpc) {
            .string => |s| {
                if (!std.mem.eql(u8, s, "2.0")) return error.message_invalid;
            },
            else => return error.message_invalid,
        }
        if (try Message.parse_request(obj)) |request| return request;
        if (try Message.parse_response(obj)) |response| return response;
        if (try Message.parse_notification(obj)) |notification| return notification;
        return error.message_invalid;
    }

    pub fn parse_request(obj: std.json.ObjectMap) !?Self {
        const method_val = obj.get("method") orelse return null;
        const method = switch (method_val) {
            .string => |s| s,
            else => return error.message_invalid,
        };
        const id_val = obj.get("id") orelse return null;
        const id_opt = try RequestId
            .parse(id_val);
        const id = id_opt orelse return null;
        const params_opt = obj.get("params");
        if (params_opt) |params| {
            switch (params) {
                .array, .object => {},
                else => return error.message_invalid,
            }
        }

        if (std.mem.eql(u8, method, "initialize")) return InitializeRequest.parse(id, params_opt);
        if (std.mem.eql(u8, method, "shutdown")) return .{ .shutdown = .{ .id = id } };
        return .{ .request_unknown = .{
            .id = id,
            .code = -32601,
            .message = "method not found",
        } };
    }

    pub fn parse_notification(obj: std.json.ObjectMap) !?Self {
        if (obj.get("id") != null) return null;
        const method_val = obj.get("method") orelse return null;
        const method = switch (method_val) {
            .string => |s| s,
            else => return error.message_invalid,
        };
        if (obj.get("params")) |params| {
            switch (params) {
                .array, .object => {},
                else => return error.message_invalid,
            }
        }
        if (std.mem.eql(u8, method, "initialized")) return .{ .initialized = {} };
        if (std.mem.eql(u8, method, "exit")) return .{ .exit = {} };
        return error.notification_unknown;
    }

    pub fn parse_response(obj: std.json.ObjectMap) !?Self {
        const id_val = obj.get("id") orelse return null;
        _ = try RequestId.parse(id_val);
        if (obj.get("result") == null and obj.get("error") == null) return null;
        if (obj.get("result") != null and obj.get("error") != null) return error.response_invalid;
        return error.response_unknown;
    }
};

const InitializeRequest = struct {
    id: RequestId,
    publish_diagnostics: bool, // in the future expand this.

    const Self = @This();

    pub fn supports_publish_diagnostics(capabilities: std.json.ObjectMap) bool {
        const doc_val = capabilities.get("textDocument") orelse return false;
        const doc = switch (doc_val) {
            .object => |o| o,
            else => return false,
        };
        const pub_val = doc.get("publishDiagnostics") orelse return false;
        switch (pub_val) {
            .object => return true,
            else => return false,
        }
    }

    pub fn parse(id: RequestId, params_opt: ?std.json.Value) Message {
        const invalid: Message = .{ .request_invalid = .{
            .id = id,
            .code = -32602,
            .message = "invalid params",
        } };
        const params_val = params_opt orelse return invalid;
        const params = switch (params_val) {
            .object => |o| o,
            else => return invalid,
        };
        const capabilities_val = params.get("capabilities") orelse return invalid;
        const capabilities = switch (capabilities_val) {
            .object => |o| o,
            else => return invalid,
        };
        return .{ .initialize = .{
            .id = id,
            .publish_diagnostics = InitializeRequest.supports_publish_diagnostics(capabilities),
        } };
    }

    pub fn respond(self: Self, writer: std.ArrayList(u8).Writer) !void {
        var json = std.json.writeStream(writer, 10);
        json.whitespace = .{ .indent = .none, .separator = false };
        try json.beginObject();
        try json.objectField("id");
        switch (self.id) {
            .string => |s| try json.emitString(s),
            .integer => |i| try json.emitNumber(i),
        }
        try json.objectField("result");
        try json.beginObject();
        try json.objectField("serverInfo");
        try json.beginObject();
        try json.objectField("name");
        try json.emitString("zig-diagnostics");
        try json.objectField("version");
        try json.emitString("v1");
        try json.endObject();
        try json.objectField("capabilities");
        try json.beginObject();
        try json.objectField("textDocumentSync");
        try json.beginObject();
        try json.objectField("openClose");
        try json.emitBool(true);
        try json.objectField("change");
        try json.emitNumber(1);
        try json.objectField("save");
        try json.beginObject();
        try json.objectField("includeText");
        try json.emitBool(true);
        try json.endObject();
        try json.endObject();
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }
};

const ShutdownRequest = struct {
    id: RequestId,

    const Self = @This();

    pub fn respond(self: Self, writer: std.ArrayList(u8).Writer) !void {
        var json = std.json.writeStream(writer, 10);
        json.whitespace = .{ .indent = .none, .separator = false };
        try json.beginObject();
        try json.objectField("id");
        switch (self.id) {
            .string => |s| try json.emitString(s),
            .integer => |i| try json.emitNumber(i),
        }
        try json.objectField("result");
        try json.emitNull();
        try json.endObject();
    }
};

const RequestError = struct {
    id: RequestId,
    code: i32,
    message: []const u8,

    const Self = @This();

    pub fn respond(self: Self, writer: std.ArrayList(u8).Writer) !void {
        var json = std.json.writeStream(writer, 10);
        json.whitespace = .{ .indent = .none, .separator = false };
        try json.beginObject();
        try json.objectField("id");
        switch (self.id) {
            .string => |s| try json.emitString(s),
            .integer => |i| try json.emitNumber(i),
        }
        try json.objectField("error");
        try json.beginObject();
        try json.objectField("code");
        try json.emitNumber(self.code);
        try json.objectField("message");
        try json.emitString(self.message);
        try json.endObject();
        try json.endObject();
    }
};
