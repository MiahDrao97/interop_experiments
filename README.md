# Interop Experiments

The primary purpose of this repository is to compare C# and Zig when it comes to lazily parsing a large JSON file.
The JSON schema comes from USPS's file feeds for informed visibilty mail tracking & reporting.
The theoretical situation is some server receiving file feeds from USPS that contain hundreds of thousands of scans.

I wanted to learn how p/invoke works while simultaneously observing the performance difference between C#'s tools and Zig's.

Generally the parsing algorithm looks like this:
1. Open JSON file (leaving it open).
2. Parse until the "events" field is found (see expected schemea: we're expecting an array of objects that we'll parse from there).
3. Lazily load each scan. Each reader implements `IEnumerable<ScanResult>`, where each `MoveNext()` call on the resulting `Enumerator<ScanResult>` simply parses the next scan object.
4. Dispose, which closes the file and frees resources.

Both readers implement the same interface, `IIvMtrFeedReader.cs`, which simply is `IEnumerable<ScanResult>` and `IDisposable`.
The C# reader is implemented in `CsharpIvMtrFeedReader.cs`. The Zig reader is platform-invokved through `ZigIvMtrFeedReader.cs`.
It expects `"open"`, `"close"`, and `"nextScan"` entry points in `zig_lib.dll`.
The zig implementation is in the `lib` directory. The entry points are defined in `/lib/src/root.zig`.
Build configuration is defined in `/lib/build.zig`.

# Setup

To run, you need .NET 8 and Zig installed ([master branch](https://ziglang.org/download/)).
This code was built using Zig version `0.14.0-dev.2370+5c6b25d9b`.

## Build

There is a `postbuild.bat` file called on a `dotnet build` command, which handles building the Zig library and unit-testing it.
It assumes that the `zig` command is added to PATH.
It then copies the binaries from the resulting `zig-out/bin/` directory into the debug and release directories on the .NET side.
Note that you may have to manually create `/bin/Debug/net8.0` and/or `/bin/Release/net8.0`.
The batch file assumes those directories already exist and copies to both.

## Run

For a more accurate comparison, please run in Release mode.
Pass in a path to a json file for this program to parse.
The expected schema is like:
```json
{
    "events": [
        {
            "imb": "",
            "mailPhase", ""
            // These fields are the only ones we care about, but there are several other fields
        }
        // however many scan objects (could be hundreds of thousands)
    ]
    // other fields
}
```
The `mailPhase` field is expected to have specific phrases.
Please refer to `IV_MTR_DataDictionary_20180810.xslx` for documentation on the USPS file feed schema.

This will run 20 iterations, parsing the first 1000, then 10000, then 20000, and finally 40000.
It will collect average, minimum, and maximum execution time parsing and iterating through those scan objects.
