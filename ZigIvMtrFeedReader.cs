using System.Collections;
using System.Runtime.InteropServices;
using System.Text;

namespace InteropExperiments;

public sealed class IvMtrFeedReader : IIvMtrFeedReader
{
    private bool _enumeratorOpened;
    private bool _disposed;

    private IvMtrFeedReader() { }

    ~IvMtrFeedReader()
    {
        LibBindings.CloseReader();
    }

    public static IvMtrFeedReader OpenFile(string filePath, bool terminateOpenReader = false)
    {
        LibBindings.NewReaderResult result = LibBindings.OpenReader(filePath);
        switch (result)
        {
            case LibBindings.NewReaderResult.Opened:
                break;
            case LibBindings.NewReaderResult.Conflict:
                if (terminateOpenReader)
                {
                    LibBindings.CloseReader();
                    return OpenFile(filePath, false);
                }
                throw new InvalidOperationException($"Thread {Thread.GetCurrentProcessorId()} already has a feeder reader opened. Cannot open another file until the current reader is closed.");
#pragma warning disable CA2201
            case LibBindings.NewReaderResult.OutOfMemory:
                throw new OutOfMemoryException($"Reader out of memory");
#pragma warning restore CA2201
        }
        return new IvMtrFeedReader();
    }

    public IEnumerator<ScanResult> GetEnumerator()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_enumeratorOpened)
        {
            throw new InvalidOperationException("Enumerator already opened for this file. Instead, dispose this reader and open a new one.");
        }
        _enumeratorOpened = true;
        return new Enumerator();
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public void Dispose()
    {
        _disposed = true;
        LibBindings.CloseReader();
        GC.SuppressFinalize(this);
    }

    private struct Enumerator : IEnumerator<ScanResult>
    {
        public ScanResult Current { get; private set; }

        readonly object IEnumerator.Current => Current;

        public void Reset() => throw new NotSupportedException($"This enumerator does not support resetting. Instead dispose the current instance of {typeof(IvMtrFeedReader)} and open a new one.");

        public bool MoveNext()
        {
            if (LibBindings.Next() is ScanResult scan)
            {
                Current = scan;
                return true;
            }
            return false;
        }

        public readonly void Dispose() { }
    }
}

internal static partial class LibBindings
{
    [LibraryImport("zig_lib.dll", EntryPoint = "open")]
    private static partial int Open(IntPtr fileName);

    [LibraryImport("zig_lib.dll", EntryPoint = "close")]
    private static partial void Close();

    [LibraryImport("zig_lib.dll", EntryPoint = "nextScan")]
    private static partial ScanResultUnmanaged NextScan();

    public enum NewReaderResult
    {
        Opened = 0,
        FailedToOpen = 1,
        Conflict = 2,
        OutOfMemory = 3
    }

    public enum ReadResult
    {
        Success = 0,
        NoActiveReader = 1,
        FailedToRead = 2,
        OutOfMemory = 3,
        Eof = -1
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScanResultUnmanaged
    {
        public int status;

        public IntPtr imb;

        public IntPtr mailPhase;

        public override readonly string ToString()
        {
            return $"{{status:{status}, imb:{imb}, mailPhase:{mailPhase}}}";
        }
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

    public static void CloseReader() => Close();

    public static ScanResult? Next()
    {
        ScanResultUnmanaged scan = NextScan();
        Console.WriteLine($"Returned scan: {scan}");

        ReadResult status = (ReadResult)scan.status;
        switch (status)
        {
#pragma warning disable CA2201
            case ReadResult.OutOfMemory:
                throw new OutOfMemoryException($"Reader out of memory");
#pragma warning restore CA2201
            case ReadResult.Eof:
                return null;
            case ReadResult.FailedToRead:
                throw new InvalidOperationException("Failed to read the file");
            case ReadResult.NoActiveReader:
                throw new InvalidOperationException("No reader has a file open at this time");
            case ReadResult.Success:
                break;
        }

        // success status: we're expecting non-null values
        if (scan.mailPhase == IntPtr.Zero)
        {
            throw new InvalidOperationException("Scan returned from reader has null mailPhase");
        }
        if (scan.imb == IntPtr.Zero)
        {
            throw new InvalidOperationException("Scan returned null for IMB");
        }
        string mailPhaseStr = Marshal.PtrToStringAnsi(scan.mailPhase) ?? throw new InvalidOperationException($"Mail phase was not valid");

        return new ScanResult
        {
            Imb = Marshal.PtrToStringAnsi(scan.imb) ?? throw new InvalidOperationException($"IMB was not valid"),
            MailPhase = (MailPhase)mailPhaseStr,
        };
    }
}
