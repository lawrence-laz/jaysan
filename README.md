# jayさん
Jaysan is a fast json library written in Zig. Currently supports serialization only.

```md
Benchmark 1: std.json
  Time (mean ± σ):     151.7 ms ±   0.9 ms    [User: 147.1 ms, System: 4.1 ms]
  Range (min … max):   149.2 ms … 153.2 ms    19 runs

Benchmark 2: jaysan
  Time (mean ± σ):      56.0 ms ±   1.1 ms    [User: 53.8 ms, System: 1.8 ms]
  Range (min … max):    53.3 ms …  57.9 ms    50 runs

Summary
  jaysan ran
    2.71 ± 0.05 times faster than std.json
```
