// (c) 2024 Lawrence Laz
// This code is licensed under MIT license (see LICENSE for details)

const std = @import("std");

const json = struct {
    pub fn stringify(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        if (isStringType(T)) {
            try writer.writeAll("\"");
        } else if (isArrayType(T)) {
            try writer.writeAll("[");
        }
        try stringifyValue(value, writer);
        if (isStringType(T)) {
            try writer.writeAll("\"");
        } else if (isArrayType(T)) {
            try writer.writeAll("]");
        }
    }

    fn stringifyValue(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Bool => try writer.writeAll(if (value) "true" else "false"),
            .Int => try writer.print("{d}", .{value}), // TODO: Handle long numbers
            .ComptimeInt => try writer.print("{d}", .{value}),
            .Float => try writer.print("{d}", .{value}),
            .ComptimeFloat => try writer.print("{d}", .{value}),
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .Array => |array_info| if (array_info.child == u8)
                        try writer.writeAll(@as([]const std.meta.Elem(ptr_info.child), value))
                    else
                        try stringifyArray(@as([]const std.meta.Elem(ptr_info.child), value), writer),
                    else => try stringifyValue(value.*, writer),
                },
                .Many, .Slice => {
                    if (ptr_info.size == .Many and ptr_info.sentinel == null)
                        @compileError("Cannot stringify type '" ++ @typeName(T) ++ "' without sentinel");
                    const slice = if (ptr_info.size == .Many) std.mem.span(value) else value;
                    if (ptr_info.child == u8)
                        try writer.writeAll(slice)
                    else
                        try stringifyArray(slice, writer);
                },
                else => @compileError("Cannot stringify type '" ++ @typeName(T) ++ "'"),
            },
            .Array => |array_info| if (array_info.child == u8)
                try writer.writeAll(@as([]const array_info.child, &value))
            else
                try stringifyArray(@as([]const array_info.child, &value), writer),
            .Struct => |struct_info| if (struct_info.is_tuple)
                try stringifyTuple(value, writer)
            else
                try stringifyStruct(value, writer),
            .Null => try writer.writeAll("null"),
            .Optional => if (value) |unwrapped| try stringifyValue(unwrapped, writer) else try writer.writeAll("null"),
            .Enum, .EnumLiteral => try writer.writeAll(@tagName(value)),
            .Union => try stringifyUnion(value, writer),
            else => @compileError("Cannot stringify type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn stringifyArray(value: anytype, writer: std.io.AnyWriter) !void {
        if (value.len == 0) {
            return;
        }
        for (value[0 .. value.len - 1]) |item| {
            try stringifyValue(item, writer);
            try writer.writeAll(","); // TODO: Optimize
        }
        try stringifyValue(value[value.len - 1], writer);
    }

    fn stringifyUnion(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const union_info = @typeInfo(T).Union;
        if (union_info.tag_type) |UnionTagType| {
            const fields: []const std.builtin.Type.UnionField = std.meta.fields(T);
            inline for (fields) |field| {
                if (value == @field(UnionTagType, field.name)) {
                    const array_open = if (isArrayType(field.type)) "[" else "";
                    const string_open = if (isStringType(field.type)) "\"" else "";
                    try writer.writeAll("{\"" ++ field.name ++ "\":" ++ array_open ++ string_open);
                    if (field.type == void) {
                        try writer.writeAll("{}");
                    } else {
                        try stringifyValue(@field(value, field.name), writer);
                    }
                    const last_array_close = if (isArrayType(field.type)) "]" else "";
                    const last_string_close = if (isStringType(field.type)) "\"" else "";
                    try writer.writeAll(last_array_close ++ last_string_close ++ "}");
                    break;
                }
            }
            return;
        } else {
            @compileError("Cannot stringify untagged union '" ++ @typeName(T) ++ "'");
        }
    }

    fn stringifyStruct(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const fields: []const std.builtin.Type.StructField = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const prev_array_close = if (i != 0 and isArrayType(fields[i - 1].type)) "]" else "";
            const prev_string_close = if (i != 0 and isStringType(fields[i - 1].type)) "\"" else "";
            const object_open_or_comma = if (i == 0) "{" else ",";
            const array_open = if (isArrayType(field.type)) "[" else "";
            const string_open = if (isStringType(field.type)) "\"" else "";
            try writer.writeAll(prev_array_close ++ prev_string_close ++ object_open_or_comma ++
                "\"" ++ field.name ++ "\":" ++
                array_open ++ string_open);
            try stringifyValue(@field(value, field.name), writer);
        }
        const last_array_close = if (isArrayType(fields[fields.len - 1].type)) "]" else "";
        const last_string_close = if (isStringType(fields[fields.len - 1].type)) "\"" else "";
        try writer.writeAll(last_array_close ++ last_string_close ++ "}");
    }

    fn stringifyTuple(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const struct_info = @typeInfo(T).Struct;
        if (!struct_info.is_tuple) @compileError("Expected a tuple but got '" ++ @typeName(T) ++ "'");
        const fields: []const std.builtin.Type.StructField = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const prev_array_close = if (i != 0 and isArrayType(fields[i - 1].type)) "]" else "";
            const prev_string_close = if (i != 0 and isStringType(fields[i - 1].type)) "\"" else "";
            const array_open_or_comma = if (i == 0) "[" else ",";
            const array_open = if (isArrayType(field.type)) "[" else "";
            const string_open = if (isStringType(field.type)) "\"" else "";
            try writer.writeAll(prev_array_close ++ prev_string_close ++ array_open_or_comma ++ array_open ++ string_open);
            try stringifyValue(@field(value, field.name), writer);
        }
        const last_array_close = if (isArrayType(fields[fields.len - 1].type)) "]" else "";
        const last_string_close = if (isStringType(fields[fields.len - 1].type)) "\"" else "";
        try writer.writeAll(last_array_close ++ last_string_close ++ "]");
    }

    inline fn isArrayType(T: type) bool {
        comptime {
            return switch (@typeInfo(T)) {
                .Array => |array_type_info| array_type_info.child != u8,
                .Pointer => |ptr_type_info| ptr_type_info.child != u8,
                else => false,
            };
        }
    }

    inline fn isStringType(T: type) bool {
        comptime {
            return switch (@typeInfo(T)) {
                .Array => |array_info| array_info.child == u8,
                .Pointer => |ptr_info| switch (ptr_info.size) {
                    .One => switch (@typeInfo(ptr_info.child)) {
                        .Array => |array_info| array_info.child == u8,
                        else => false,
                    },
                    .Many, .Slice => ptr_info.child == u8,
                    else => false,
                },
                .Enum, .EnumLiteral => true,
                else => false,
            };
        }
    }

    pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        try stringify(value, buf.writer().any());
        return buf.toOwnedSlice();
    }
};

test "stringify struct" {
    const Bar = struct {
        bar: i32,
        barbar: []const u8,
    };
    const Foo = struct {
        bars: []const Bar,
        foo: f32,
        foofoo: []const u8,
    };
    try testStringify(
        "{\"bars\":[{\"bar\":123,\"barbar\":\"first\"},{\"bar\":234,\"barbar\":\"second\"}],\"foo\":345.678,\"foofoo\":\"Hello\"}",
        Foo{
            .bars = &.{
                .{ .bar = 123, .barbar = "first" },
                .{ .bar = 234, .barbar = "second" },
            },
            .foo = 345.678,
            .foofoo = "Hello",
        },
    );
}

test "stringify basic types" {
    try testStringify("false", false);
    try testStringify("true", true);
    try testStringify("null", null);
    try testStringify("null", @as(?u8, null));
    try testStringify("null", @as(?*u32, null));
    try testStringify("42", 42);
    try testStringify("42", 42.0);
    try testStringify("42", @as(u8, 42));
    try testStringify("42", @as(u128, 42));
    try testStringify("9999999999999999", 9999999999999999);
    try testStringify("42.123", @as(f32, 42.123));
    try testStringify("42", @as(f64, 42));
}

test "stringify string" {
    try testStringify("\"hello\"", "hello");
    try testStringify("\"hello\"", @as([*:0]const u8, "hello"));
}

test "stringify enum" {
    const Foo = enum { foo, bar };
    try testStringify("\"foo\"", Foo.foo);
    try testStringify("\"bar\"", Foo.bar);

    // TODO
    // const Bar = enum(u8) { foo = 0, _ };
    // try testStringify("\"foo\"", Bar.foo);
    // try testStringify("1", @as(Bar, @enumFromInt(1)));

    try testStringify("\"foo\"", .foo);
    try testStringify("\"bar\"", .bar);
}

test "stringify tagged union" {
    const T = union(enum) {
        nothing,
        foo: u32,
        bar: bool,
    };
    try testStringify("{\"nothing\":{}}", T{ .nothing = {} });
    try testStringify("{\"foo\":42}", T{ .foo = 42 });
    try testStringify("{\"bar\":true}", T{ .bar = true });
}

test "stringify array" {
    const Foo = struct { foo: u32 };
    try testStringify("[{\"foo\":42},{\"foo\":100},{\"foo\":1000}]", [_]Foo{
        Foo{ .foo = 42 },
        Foo{ .foo = 100 },
        Foo{ .foo = 1000 },
    });
}

test "stringify tuple" {
    try testStringify("[\"foo\",42]", std.meta.Tuple(&.{ []const u8, usize }){ "foo", 42 });
}

fn testStringify(expected: []const u8, value: anytype) !void {
    const actual = try json.stringifyAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
