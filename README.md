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
Benchmark 1: zig-stdjson
  Time (mean ± σ):     141.9 ms ±   1.1 ms    [User: 140.4 ms, System: 1.0 ms]
  Range (min … max):   140.1 ms … 144.1 ms    20 runs

Benchmark 2: zig-jaysan
  Time (mean ± σ):      46.8 ms ±   1.3 ms    [User: 46.2 ms, System: 0.4 ms]
  Range (min … max):    43.1 ms …  49.2 ms    61 runs

Benchmark 3: rust-serde
  Time (mean ± σ):      46.9 ms ±   0.9 ms    [User: 45.8 ms, System: 0.9 ms]
  Range (min … max):    45.9 ms …  50.9 ms    62 runs

Summary
  zig-jaysan
    1.00 ± 0.03 times faster than rust-serde
    3.03 ± 0.09 times faster than zig-stdjson
```
