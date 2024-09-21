<h1 align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/c/c9/JSON_vector_logo.svg/160px-JSON_vector_logo.svg.png" width="64"><br>
  Jayさん
  <br>
</h1>

Jaysan is a fast json library written in Zig. Currently supports serialization only.

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const Foo = struct {
    foo: i32,
    bar: []const u8,
};

const string = try json.stringifyAlloc(
    gpa.allocator(),
    Foo{
        .foo = 123,
        .bar = "Hello, world!",
    },
);

// {"foo":123,"bar":"Hello, world!"}
```

```md
Benchmark 1: stdjson
  Time (mean ± σ):     143.6 ms ±   1.1 ms    [User: 140.5 ms, System: 2.7 ms]
  Range (min … max):   141.5 ms … 146.6 ms    20 runs

Benchmark 2: jaysan
  Time (mean ± σ):      48.5 ms ±   0.8 ms    [User: 47.0 ms, System: 1.2 ms]
  Range (min … max):    46.4 ms …  50.0 ms    60 runs

Summary
  jaysan
    2.96 ± 0.05 times faster than stdjson
```
