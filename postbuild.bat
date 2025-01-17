cd lib
zig build -Doptimize=ReleaseSafe

cd ..
copy .\lib\zig-out\bin\* .\bin\Debug\net8.0
