const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var repeat: usize = 100_000;
    while (repeat >= 1) : (repeat -= 1) {
        var buf: [100_000]u8 = .{0} ** 100_000;
        var writer = std.io.fixedBufferStream(&buf);
        const input: []const Foo = &.{
            .{
                .id = 123456789,
                .foo_enum = .foo,
                .bars = .{
                    .{ .bar = -123, .enabled = true, .values = .{ 1.23, 2.34, 3.45, 4.56, 5.67 } },
                    .{ .bar = 0, .enabled = false, .values = .{ 2.34, 3.45, 4.56, 5.67, 6.78 } },
                    .{ .bar = 123, .enabled = true, .values = .{ 3.45, 4.56, 5.67, 6.78, 7.89 } },
                },
                .baz = false,
                .url = "https://github.com/lawrence-laz/jaysan/blob/d32edeaef8315c1447ff2c8c4d5f114461080e12/src/main.zig#L360C1-L443C2",
                .created_at = "2013-01-10T07:58:30Z",
            },
        };

        try json.toWriter(null, input, writer.writer().any());
    }
}

const Foo = struct {
    id: u64,
    foo_enum: FooEnum,
    bars: [3]Bar,
    baz: bool,
    url: []const u8,
    created_at: []const u8,
};

const Bar = struct {
    bar: i32,
    enabled: bool,
    values: [5]f32,
};

const FooEnum = enum { foo, bar, baz, fizz, fuzz, feh };
