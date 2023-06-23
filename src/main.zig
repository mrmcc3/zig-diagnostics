const std = @import("std");
const lsp_io = @import("./lsp_io.zig");
const Server = @import("./server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var lsp = lsp_io.init(arena.allocator(), std.io.getStdIn(), std.io.getStdOut());
    defer lsp.deinit();

    var response = std.ArrayList(u8).init(arena.allocator());
    defer response.deinit();

    var server = Server.init(response.writer());

    while (true) {
        response.shrinkRetainingCapacity(0);

        var json = std.json.parseFromSlice(
            std.json.Value,
            gpa.allocator(),
            try lsp.read(),
            .{},
        ) catch |e| {
            std.debug.print("\njson_error: {any}\n", .{e});
            server.err(-32700, "parse error") catch continue;
            try lsp.write(response.items);
            continue;
        };
        defer json.deinit();

        server.process(json.value) catch |e| {
            switch (e) {
                error.exit => break,
                error.premature_exit => return e,
                else => {
                    std.debug.print("\nprocess_error: {any}\n", .{e});
                    continue;
                },
            }
        };

        if (response.items.len > 0) try lsp.write(response.items);
    }
}

test {
    std.testing.refAllDecls(@This());
}
