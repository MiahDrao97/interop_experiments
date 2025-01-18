using System.Runtime.InteropServices;
using System.Text;

namespace InteropExperiments;

public sealed class IvMtrFeedReader : IDisposable
{
    private IvMtrFeedReader() { }

    public static IvMtrFeedReader OpenFile(string filePath)
    {
        LibBindings.NewReaderResult result = LibBindings.OpenReader(filePath);
        switch (result)
        {
            case LibBindings.NewReaderResult.Opened:
                break;
            case LibBindings.NewReaderResult.Conflict:
                throw new InvalidOperationException($"Thread {Thread.GetCurrentProcessorId()} already has a feeder reader opened. Cannot open another file until the current reader is closed.");
            case LibBindings.NewReaderResult.OutOfMemory:
#pragma warning disable CA2201
                throw new OutOfMemoryException($"Reader out of memory");
#pragma warning restore CA2201
        }
        return new IvMtrFeedReader();
    }

    public void Dispose()
    {
        LibBindings.CloseReader();
    }
}

internal static partial class LibBindings
{
    [LibraryImport("zig_lib.dll", EntryPoint = "open")]
    private static partial int Open(IntPtr fileName);

    [LibraryImport("zig_lib.dll", EntryPoint = "close")]
    private static partial void Close();

    public enum NewReaderResult
    {
        Opened = 0,
        Conflict = 1,
        OutOfMemory = 2
    }

    public static NewReaderResult OpenReader(string fileName)
    {
        unsafe
        {
            fixed (byte* ptr = Encoding.UTF8.GetBytes(fileName))
            {
                int result = Open(new IntPtr(ptr));
                return (NewReaderResult)result;
            }
        }
    }

    public static void CloseReader()
    {
        Close();
    }
}
