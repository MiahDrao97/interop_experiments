using System.Collections;
using System.Runtime.InteropServices;
using System.Text;

namespace InteropExperiments;

/// <inheritdoc cref="IIvMtrFeedReader" />
public sealed class ZigIvMtrFeedReader : IIvMtrFeedReader
{
    private bool _enumeratorOpened;
    private bool _disposed;

    private ZigIvMtrFeedReader() { }

    ~ZigIvMtrFeedReader()
    {
        LibBindings.CloseReader();
    }

    /// <summary>
    /// Open an IV-MTR feed file
    /// </summary>
    public static ZigIvMtrFeedReader OpenFile(string filePath, bool terminateOpenReader = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);

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
        return new ZigIvMtrFeedReader();
    }

    /// <inheritdoc />
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

    /// <inheritdoc />
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    /// <summary>
    /// Frees unmanaged memory
    /// </summary>
    public void Dispose()
    {
        _disposed = true;
        LibBindings.CloseReader();
        GC.SuppressFinalize(this);
    }

    private struct Enumerator : IEnumerator<ScanResult>
    {
        /// <inheritdoc />
        public ScanResult Current { get; private set; }

        /// <inheritdoc />
        readonly object IEnumerator.Current => Current;

        /// <inheritdoc />
        public void Reset() => throw new NotSupportedException($"This enumerator does not support resetting. Instead dispose the current instance of {typeof(ZigIvMtrFeedReader)} and open a new one.");

        /// <inheritdoc />
        public bool MoveNext()
        {
            if (LibBindings.Next() is ScanResult scan)
            {
                Current = scan;
                return true;
            }
            return false;
        }

        /// <inheritdoc />
        public readonly void Dispose() { }
    }
}

/// <summary>
/// Lib bindings for `zig_lib.dll`
/// </summary>
internal static partial class LibBindings
{
    // be OS-aware
#if WINDOWS
    private const string _libFile = "zig_lib.dll";
#else
    // Linux dynamic library file extension
    private const string _libFile = "zig_lib.so";
#endif

    [LibraryImport(_libFile, EntryPoint = "open")]
    private static unsafe partial sbyte Open(byte* fileName);

    [LibraryImport(_libFile, EntryPoint = "close")]
    private static partial void Close();

    [LibraryImport(_libFile, EntryPoint = "nextScan")]
    private static partial ScanResultUnmanaged NextScan();

    [LibraryImport(_libFile, EntryPoint = "lastError")]
    private static partial IntPtr LastError();

    /// <summary>
    /// Represents the status code when opening a new reader
    /// </summary>
    public enum NewReaderResult
    {
        /// <summary>
        /// Successfully opened
        /// </summary>
        Opened = 0,

        /// <summary>
        /// Failed to open (check console logs for more specifics: this could be due to the OS preventing the file being read)
        /// </summary>
        FailedToOpen = 1,

        /// <summary>
        /// There is already an open reader on this thread
        /// </summary>
        Conflict = 2,

        /// <summary>
        /// The reader ran out of memory (detrimental error if this ever happens)
        /// </summary>
        OutOfMemory = 3
    }

    /// <summary>
    /// Represents the status code when reading the next scan from the feed
    /// </summary>
    public enum ReadResult
    {
        /// <summary>
        /// Successfully read the next scan
        /// </summary>
        Success = 0,

        /// <summary>
        /// No reader is open
        /// </summary>
        NoActiveReader = 1,

        /// <summary>
        /// Failed to read: this would be due to the contents of the file not matching expectations.
        /// This would very likely be a bug in the unmanaged code, so definitely check the console logs for what caused this error.
        /// </summary>
        FailedToRead = 2,

        /// <summary>
        /// The reader ran out of memory (detrimental error if this ever happens)
        /// </summary>
        OutOfMemory = 3,

        /// <summary>
        /// End of file (not an error, but we use this code to mark the end of the file feed)
        /// </summary>
        Eof = -1
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScanResultUnmanaged
    {
        /// <summary>
        /// Status, matching <see cref="ReadResult"/>
        /// </summary>
        public sbyte status;

        /// <summary>
        /// IMB parsed from the feed file. Should be marshalled as an ANSI string.
        /// </summary>
        /// <remarks>
        /// WARNING : The value will be 0 if the <see cref="status"/> is anything other than <see cref="ReadResult.Success"/>.
        /// This indicates that this is pointing to address 0, which is NULL.
        ///
        /// </remarks>
        public IntPtr imb;

        /// <summary>
        /// Mail phase parsed from the feed file. Should be marshalled as an ANSI string.
        /// </summary>
        /// <remarks>
        /// WARNING : The value will be 0 if the <see cref="status"/> is anything other than <see cref="ReadResult.Success"/>.
        /// This indicates that this is pointing to address 0, which is NULL.
        ///
        /// </remarks>
        public IntPtr mailPhase;

        public override readonly string ToString()
        {
            return $"{{status:{status}, imb:{imb}, mailPhase:{mailPhase}}}";
        }
    }

    /// <summary>
    /// Open the underlying reader
    /// </summary>
    public static NewReaderResult OpenReader(string fileName)
    {
        unsafe
        {
            fixed (byte* ptr = Encoding.UTF8.GetBytes(fileName))
            {
                int result = Open(ptr);
                return (NewReaderResult)result;
            }
        }
    }

    /// <summary>
    /// Close the underlying reader and free unmanaged resources
    /// </summary>
    public static void CloseReader() => Close();

    /// <summary>
    /// Get the last error from the lib
    /// </summary>
    public static string? GetLastError()
    {
        IntPtr str = LastError();
        if (str == IntPtr.Zero)
        {
            return null;
        }
        return Marshal.PtrToStringUTF8(str);
    }

    /// <summary>
    /// Get the next scan result or null if end of file.
    /// </summary>
    public static ScanResult? Next()
    {
        ScanResultUnmanaged scan = NextScan();
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
                throw new InvalidOperationException($"Failed to read the file:\n{GetLastError()}");
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
