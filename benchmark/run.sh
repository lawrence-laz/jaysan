cd zig-jaysan/ && zig build --release=safe && cd ..
cd zig-getty-json/ && zig build --release=safe && cd ..

hyperfine --show-output --warmup 3 \
    zig-getty-json/zig-out/bin/zig-getty-json-bench \
    zig-jaysan/zig-out/bin/zig-jaysan-bench
