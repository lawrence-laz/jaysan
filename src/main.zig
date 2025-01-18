// (c) 2025 Lawrence Laz
// This code is licensed under MIT license (see LICENSE for details)

// TOOD: Implement parsing as per https://www.json.org/json-en.html
// TODO: Pass the test suite at https://github.com/nst/JSONTestSuite

const std = @import("std");

pub const json = struct {
    pub fn stringify(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        if (isString(T, value)) {
            try writer.writeAll("\"");
        } else if (isArray(T)) {
            try writer.writeAll("[");
        }
        try stringifyValue(value, writer);
        if (isString(T, value)) {
            try writer.writeAll("\"");
        } else if (isArray(T)) {
            try writer.writeAll("]");
        }
    }

    fn stringifyValue(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try writer.writeAll(if (value) "true" else "false"),
            .int => try stringifyInt(value, writer),
            .comptime_int => try writer.print("{d}", .{value}),
            .float => try writer.print("{d}", .{value}),
            .comptime_float => try writer.print("{d}", .{value}),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| if (array_info.child == u8)
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
            .array => |array_info| if (array_info.child == u8)
                try writer.writeAll(@as([]const array_info.child, &value))
            else
                try stringifyArray(@as([]const array_info.child, &value), writer),
            .@"struct" => |struct_info| if (struct_info.is_tuple)
                try stringifyTuple(value, writer)
            else if (isArray(T))
                try stringifyArray(value.items, writer)
            else if (isHashMap(T))
                try stringifyHashMap(value, writer)
            else
                try stringifyStruct(value, writer),
            .null => try writer.writeAll("null"),
            .optional => if (value) |unwrapped| try stringifyValue(unwrapped, writer) else try writer.writeAll("null"),
            .@"enum" => |enum_info| if (enum_info.is_exhaustive) try writer.writeAll(@tagName(value)) else {
                if (std.enums.tagName(T, value)) |tag|
                    try writer.writeAll(tag)
                else
                    try writer.print("{d}", .{@as(enum_info.tag_type, @intFromEnum(value))});
            },
            .enum_literal => try writer.writeAll(@tagName(value)),
            .@"union" => try stringifyUnion(value, writer),
            else => @compileError("Cannot stringify type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn stringifyInt(value: anytype, writer: std.io.AnyWriter) !void {
        const char_map = "0123456789";
        const T = @TypeOf(value);
        const int_info = @typeInfo(T).int;
        var abs_value = if (int_info.signedness == .unsigned) value else @abs(value);
        const digit_count = comptime blk: {
            break :blk std.math.log10(std.math.maxInt(T)) +
                1 +
                (if (int_info.signedness == .signed) 1 else 0);
        };
        var buf: [digit_count]u8 = undefined;
        var index: usize = digit_count - 1;
        if (abs_value == 0) {
            buf[index] = '0';
            index -= 1;
        } else while (abs_value != 0 and index != 0) {
            buf[index] = char_map[@as(usize, @intCast(abs_value % 10))];
            index -= 1;
            abs_value /= 10;
        }
        if (int_info.signedness == .signed and value < 0) {
            buf[index] = '-';
        } else {
            index += 1;
        }
        try writer.writeAll(buf[index..]);
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
        const union_info = @typeInfo(T).@"union";
        if (union_info.tag_type) |UnionTagType| {
            const fields: []const std.builtin.Type.UnionField = std.meta.fields(T);
            inline for (fields) |field| {
                if (value == @field(UnionTagType, field.name)) {
                    const array_open = if (isArray(field.type)) "[" else "";
                    const string_open = if (isString(field.type, @field(value, field.name))) "\"" else "";
                    try writer.writeAll("{\"" ++ field.name ++ "\":" ++ array_open ++ string_open);
                    if (field.type == void) {
                        try writer.writeAll("{}");
                    } else {
                        try stringifyValue(@field(value, field.name), writer);
                    }
                    const last_array_close = if (isArray(field.type)) "]" else "";
                    const last_string_close = if (isString(field.type, @field(value, field.name))) "\"" else "";
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
            const prev_field: ?std.builtin.Type.StructField = if (i != 0) fields[i - 1] else null;
            const prev_array_close = if (prev_field != null and isArray(prev_field.?.type)) "]" else "";
            const prev_string_close = if (prev_field != null and isString(prev_field.?.type, @field(value, prev_field.?.name))) "\"" else "";
            const object_open_or_comma = if (i == 0) "{" else ",";
            const array_open = if (isArray(field.type)) "[" else "";
            const string_open = if (isString(field.type, @field(value, field.name))) "\"" else "";
            try writer.writeAll(prev_array_close ++ prev_string_close ++ object_open_or_comma ++
                "\"" ++ field.name ++ "\":" ++
                array_open ++ string_open);
            try stringifyValue(@field(value, field.name), writer);
        }
        const last_field = fields[fields.len - 1];
        const last_array_close = if (isArray(last_field.type)) "]" else "";
        const last_string_close = if (isString(last_field.type, @field(value, last_field.name))) "\"" else "";
        try writer.writeAll(last_array_close ++ last_string_close ++ "}");
    }

    fn stringifyTuple(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const struct_info = @typeInfo(T).@"struct";
        if (!struct_info.is_tuple) @compileError("Expected a tuple but got '" ++ @typeName(T) ++ "'");
        const fields: []const std.builtin.Type.StructField = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const prev_field: ?std.builtin.Type.StructField = if (i != 0) fields[i - 1] else null;
            const prev_array_close = if (i != 0 and isArray(prev_field.?.type)) "]" else "";
            const prev_string_close = if (i != 0 and isString(prev_field.?.type, @field(value, prev_field.?.name))) "\"" else "";
            const array_open_or_comma = if (i == 0) "[" else ",";
            const array_open = if (isArray(field.type)) "[" else "";
            const string_open = if (isString(field.type, @field(value, field.name))) "\"" else "";
            try writer.writeAll(prev_array_close ++ prev_string_close ++ array_open_or_comma ++ array_open ++ string_open);
            try stringifyValue(@field(value, field.name), writer);
        }
        const last_field = fields[fields.len - 1];
        const last_array_close = if (isArray(last_field.type)) "]" else "";
        const last_string_close = if (isString(last_field.type, @field(value, last_field.name))) "\"" else "";
        try writer.writeAll(last_array_close ++ last_string_close ++ "]");
    }

    fn stringifyHashMap(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const TKey = getHashMapKeyType(T);
        const TVal = getHashMapValueType(T);
        var iter = value.iterator();
        var prev_val: ?TVal = null;
        while (iter.next()) |kvp| {
            if (prev_val != null and isArray(TVal)) try writer.writeByte(']');
            if (prev_val != null and isString(TVal, prev_val.?)) try writer.writeByte('"');
            const object_open_or_comma = if (prev_val == null) "{" else ",";
            const array_open = if (isArray(TVal)) "[" else "";
            const string_open = if (isString(TVal, kvp.value_ptr.*)) "\"" else "";
            try writer.writeAll(object_open_or_comma ++ "\"");
            if (hasToString(TKey)) {
                try stringifyValue(kvp.key_ptr.toString(), writer);
            } else {
                try stringifyValue(kvp.key_ptr.*, writer);
            }
            try writer.writeAll("\":" ++ array_open ++ string_open);
            try stringifyValue(kvp.value_ptr.*, writer);
            prev_val = kvp.value_ptr.*;
        }
        if (prev_val == null) try writer.writeByte('{');
        if (isArray(TVal)) try writer.writeByte(']');
        if (prev_val != null and isString(TVal, prev_val.?)) try writer.writeByte('"');
        try writer.writeByte('}');
    }

    inline fn isArray(T: type) bool {
        comptime {
            return switch (@typeInfo(T)) {
                .array => |array_type_info| array_type_info.child != u8,
                .pointer => |ptr_type_info| ptr_type_info.child != u8,
                .@"struct" => @hasField(T, "items") and
                    (T == std.ArrayList(std.meta.Child(std.meta.FieldType(T, .items))) or
                    T == std.ArrayListUnmanaged(std.meta.Child(std.meta.FieldType(T, .items)))),
                else => false,
            };
        }
    }

    inline fn isHashMap(comptime T: type) bool {
        comptime {
            return std.meta.activeTag(@typeInfo(T)) == .@"struct" and
                @hasDecl(T, "iterator") and
                (T == std.StringHashMapUnmanaged(getHashMapValueType(T)) or
                T == std.AutoHashMapUnmanaged(getHashMapKeyType(T), getHashMapValueType(T)));
        }
    }

    inline fn hasToString(comptime T: type) bool {
        comptime {
            return switch (@typeInfo(T)) {
                .@"struct" => @hasDecl(T, "toString"),
                else => false,
            };
        }
    }

    inline fn getHashMapKeyType(comptime T: type) type {
        return @typeInfo(@typeInfo(@TypeOf(T.getKey)).@"fn".return_type.?).optional.child;
    }

    inline fn getHashMapValueType(comptime T: type) type {
        return @typeInfo(@typeInfo(@TypeOf(T.get)).@"fn".return_type.?).optional.child;
    }

    inline fn isString(T: type, val: T) bool {
        return switch (@typeInfo(T)) {
            .array => |array_info| array_info.child == u8,
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| array_info.child == u8,
                    else => false,
                },
                .Many, .Slice => ptr_info.child == u8,
                else => false,
            },
            .@"enum" => |enum_info| if (enum_info.is_exhaustive)
                true
            else
                std.enums.tagName(T, val) != null,
            .enum_literal => true,
            else => false,
        };
    }

    pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        try stringify(value, buf.writer().any());
        return buf.toOwnedSlice();
    }

    const Parser = struct {
        const buf_len: usize = 256;

        buf: [buf_len]u8 = .{0} ** buf_len,
        slice: []u8 = &.{},
        reader: std.io.AnyReader,

        fn init(reader: std.io.AnyReader) Parser {
            return .{ .reader = reader };
        }

        fn feed(parser: *Parser) !void {
            if (parser.slice.len == 0) {
                const bytes_read = try parser.reader.read(&parser.buf);
                parser.slice = (&parser.buf)[0..bytes_read];
            }
        }

        fn peekByte(parser: *Parser) !?u8 {
            try parser.feed();
            return parser.slice[0];
        }

        fn peekBytesAtLeast(parser: *Parser, comptime len: usize) !?[]const u8 {
            if (len > buf_len) @compileError("peekBytes len has to be less than 256");
            try parser.feed();
            return if (len < parser.slice.len) parser.slice[0..len] else parser.slice;
        }

        fn consumeByte(parser: *Parser) !?u8 {
            try parser.feed();
            defer parser.slice = parser.slice[1..];
            return parser.slice[0];
        }

        fn consumeWhitespace(parser: *Parser) !void {
            try parser.feed();
            while (try parser.peekByte()) |byte| {
                switch (byte) {
                    ' ', '\n', '\r', '\t' => _ = try parser.consumeByte(),
                    else => return,
                }
            }
        }

        fn checkSlice(parser: *Parser, comptime slice: []const u8) !bool {
            return std.mem.eql(u8, slice, try parser.peekBytesAtLeast(slice.len) orelse "");
        }
    };

    pub fn parse(comptime T: type, reader: std.io.AnyReader) !T {
        var parser: Parser = .init(reader);
        try parser.consumeWhitespace();
        return try parseType(T, &parser);
    }

    fn parseType(comptime T: type, parser: *Parser) !T {
        switch (@typeInfo(T)) {
            .bool => return try parseBool(parser),
            .int => @compileError("int not implemented"),
            .comptime_int => @compileError("comptime int not implemented"),
            .float => @compileError("float not implemented"),
            .comptime_float => @compileError("comtime float not implemented"),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| if (array_info.child == u8)
                        @compileError("string not implemented")
                    else
                        @compileError("array not implemented"),
                    else => @compileError("value not implemented"),
                },
                .Many, .Slice => {
                    // if (ptr_info.size == .Many and ptr_info.sentinel == null)
                    //     @compileError("Cannot stringify type '" ++ @typeName(T) ++ "' without sentinel");
                    // const slice = if (ptr_info.size == .Many) std.mem.span(value) else value;
                    if (ptr_info.child == u8)
                        @compileError("string not implemented")
                    else
                        @compileError("array not implemented");
                },
                else => @compileError("Cannot stringify type '" ++ @typeName(T) ++ "'"),
            },
            .array => |array_info| if (array_info.child == u8)
                @compileError("string not implemented")
            else
                @compileError("array not implemented"),
            .@"struct" => |struct_info| if (struct_info.is_tuple)
                @compileError("tuple not implemented")
            else if (isArray(T))
                @compileError("array list not implemented")
            else if (isHashMap(T))
                @compileError("hashmap not implemented")
            else
                @compileError("struct not implemented"),
            .null => @compileError("null not implemented"),
            .optional => |optional_info| return try parseOptional(optional_info.child, parser),
            .@"enum" => |enum_info| if (enum_info.is_exhaustive) {
                @compileError("exhaustivve enum not implemented");
            } else {
                @compileError("non-exhaustive enum not implemented");
            },
            .enum_literal => @compileError("enum literal not implemented"),
            .@"union" => @compileError("union not implemented"),
            else => @compileError("Cannot parse type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn parseBool(parser: *Parser) !bool {
        if (try parser.peekByte()) |byte|
            switch (byte) {
                't' => return if (try parser.checkSlice("true")) true else error.invalid_json,
                'f' => return if (try parser.checkSlice("false")) false else error.invalid_json,
                else => return error.invalid_json,
            }
        else
            return error.invalid_json;
    }

    fn parseOptional(comptime T: type, parser: *Parser) !?T {
        if (try parser.peekByte()) |byte|
            switch (byte) {
                'n' => return if (try parser.checkSlice("null")) null else error.invalid_json,
                else => return try parseType(T, parser),
            }
        else
            return error.invalid_json;
    }

    // TODO: parseIntoExisting - this one might not require all fields, but let's not do this until there's actually a need

    // parse functions should require value, there should be optional parse function that accepts nulls
    // so if struct is not optional, then the parser treats null as invalid_json
    // fn parseValueBool(
    //     parser: *Parser,
    // ) !bool {}

    pub fn parseFromSlice(comptime T: type, slice: []const u8) !T {
        var stream = std.io.fixedBufferStream(slice);
        return try parse(T, stream.reader().any());
    }
};

test "parse" {
    try std.testing.expectEqual(true, try json.parseFromSlice(bool,
        \\            
        \\  true 
    ));
    try std.testing.expectEqual(true, try json.parseFromSlice(bool, "true "));
    try std.testing.expectError(error.invalid_json, json.parseFromSlice(bool, "tru"));
    try std.testing.expectEqual(false, try json.parseFromSlice(bool,
        \\            
        \\  false 
    ));
    try std.testing.expectEqual(false, try json.parseFromSlice(bool, "false "));
    try std.testing.expectError(error.invalid_json, json.parseFromSlice(bool, "fals"));
    try std.testing.expectEqual(true, try json.parseFromSlice(?bool, "true "));
    try std.testing.expectEqual(null, try json.parseFromSlice(?bool, "null"));
    try std.testing.expectError(error.invalid_json, json.parseFromSlice(?bool, "nil"));
}

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
    try testStringify("-2147483648", @as(i32, -2147483648));
    try testStringify("0", @as(i32, 0));
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

    const Bar = enum(u8) { foo = 0, _ };
    try testStringify("\"foo\"", Bar.foo);
    try testStringify("1", @as(Bar, @enumFromInt(1)));

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

test "stringify std.ArrayList and std.ArrayListUnmanaged" {
    {
        var list: std.ArrayListUnmanaged(u32) = .{};
        defer list.deinit(std.testing.allocator);
        try list.append(std.testing.allocator, 1);
        try list.append(std.testing.allocator, 2);
        try list.append(std.testing.allocator, 3);
        try testStringify("[1,2,3]", list);
    }
    {
        var list = std.ArrayList(u32).init(std.testing.allocator);
        defer list.deinit();
        try list.append(1);
        try list.append(2);
        try list.append(3);
        try testStringify("[1,2,3]", list);
    }
}

test "stringify hash maps" {
    {
        // u32 -> bool
        var hashmap: std.AutoHashMapUnmanaged(u32, bool) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, 123, true);
        try hashmap.put(std.testing.allocator, 456, false);
        try testStringify("{\"123\":true,\"456\":false}", hashmap);
    }
    {
        // bool -> u32
        var hashmap: std.AutoHashMapUnmanaged(bool, u32) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, true, 123);
        try hashmap.put(std.testing.allocator, false, 456);
        try testStringify("{\"true\":123,\"false\":456}", hashmap);
    }
    {
        // u32 -> ArrayList(struct)
        const Foo = struct { foo: []const u8, bar: f32 };
        var hashmap: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(Foo)) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, 1, .{});
        defer hashmap.getPtr(1).?.deinit(std.testing.allocator);
        try hashmap.getPtr(1).?.append(std.testing.allocator, .{ .foo = "hello", .bar = 123 });
        try hashmap.getPtr(1).?.append(std.testing.allocator, .{ .foo = "world", .bar = 456 });
        try hashmap.put(std.testing.allocator, 2, .{});
        defer hashmap.getPtr(2).?.deinit(std.testing.allocator);
        try hashmap.getPtr(2).?.append(std.testing.allocator, .{ .foo = "bye", .bar = 789 });
        try hashmap.getPtr(2).?.append(std.testing.allocator, .{ .foo = "world", .bar = 0.1 });
        try testStringify("{\"1\":[{\"foo\":\"hello\",\"bar\":123},{\"foo\":\"world\",\"bar\":456}],\"2\":[{\"foo\":\"bye\",\"bar\":789},{\"foo\":\"world\",\"bar\":0.1}]}", hashmap);
    }
    {
        // string -> string
        var hashmap: std.StringHashMapUnmanaged([]const u8) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, "hello", "world");
        try hashmap.put(std.testing.allocator, "bye", "world");
        try testStringify("{\"hello\":\"world\",\"bye\":\"world\"}", hashmap);
    }
    {
        // struct.toString() -> bool
        const Foo = struct {
            foo: [10]u8,
            bar: [10]u8,
            pub fn toString(self: @This()) [20]u8 {
                var buf: [20]u8 = .{0} ** 20;
                buf[0..10].* = self.foo;
                buf[10..20].* = self.bar;
                return buf;
            }
        };
        var hashmap: std.AutoHashMapUnmanaged(Foo, bool) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, .{ .foo = "1234567890".*, .bar = "abcdefghij".* }, true);
        try hashmap.put(std.testing.allocator, .{ .foo = "abcdefghij".*, .bar = "1234567890".* }, false);
        try testStringify("{\"1234567890abcdefghij\":true,\"abcdefghij1234567890\":false}", hashmap);
    }
    {
        // empty
        var hashmap: std.AutoHashMapUnmanaged(u32, u32) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try testStringify("{}", hashmap);
    }
}

fn testStringify(expected: []const u8, value: anytype) !void {
    const actual = try json.stringifyAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
