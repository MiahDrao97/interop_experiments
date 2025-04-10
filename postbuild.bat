cd lib
zig build test -freference-trace --summary all
zig build -Doptimize=ReleaseSafe -freference-trace --summary all

cd ..
copy .\lib\zig-out\bin\* .\bin\Debug\net8.0
copy .\lib\zig-out\bin\* .\bin\Release\net8.0
