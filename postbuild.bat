cd lib
zig build test -freference-trace --summary all
zig build -Doptimize=ReleaseFast -freference-trace --summary all

cd ..
copy .\lib\zig-out\bin\* .\bin\Debug\net8.0
