using System.Collections;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace InteropExperiments;

public sealed class IvMtrFeedReader : IEnumerable<ScanResult>, IDisposable
{
    private bool _enumeratorOpened;

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
            case LibBindings.NewReaderResult.OutOfMemory:
#pragma warning disable CA2201
                throw new OutOfMemoryException($"Reader out of memory");
#pragma warning restore CA2201
        }
        return new IvMtrFeedReader();
    }

    public IEnumerator<ScanResult> GetEnumerator()
    {
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

#pragma warning disable CS0649
    private struct ScanResultUnmanaged
    {
        public int status;

        public IntPtr scan;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScanUnmanaged
    {
        public IntPtr imb;

        public UIntPtr imb_len;

        public IntPtr mailPhase;

        public UIntPtr mailPhase_len;

        public override readonly string ToString()
        {
            return $"{{imb:{imb}, imb_len:{imb_len}, mailPhase:{mailPhase}, mailPhase_len:{mailPhase_len}}}";
        }
    }
#pragma warning restore CS0649

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

    public static ScanResult? Next()
    {
        ScanResultUnmanaged result = NextScan();
        ReadResult status = (ReadResult)result.status;
        switch (status)
        {
            case ReadResult.OutOfMemory:
#pragma warning disable CA2201
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

        if (result.scan == IntPtr.Zero)
        {
            // this would be a bug
            throw new InvalidOperationException("Reader status indicated success but returned a null scan object.");
        }

        ScanUnmanaged scan = Marshal.PtrToStructure<ScanUnmanaged>(result.scan);
        Console.WriteLine($"Returned scan: {scan}");
        if (scan.mailPhase == IntPtr.Zero)
        {
            throw new InvalidOperationException("Scan returned from reader has null mailPhase");
        }
        if (scan.imb == IntPtr.Zero)
        {
            throw new InvalidOperationException("Scan returned null for IMB");
        }
        string mailPhaseStr = Marshal.PtrToStringAnsi(scan.mailPhase) ?? throw new InvalidOperationException($"Mail phase was not valid");
        if (!MailPhase.Steps.TryGetValue(mailPhaseStr, out float mailPhase))
        {
            throw new InvalidOperationException($"Mail phase '{mailPhaseStr}' not recognized");
        }

        return new ScanResult
        {
            Imb = Marshal.PtrToStringAnsi(scan.imb) ?? throw new InvalidOperationException($"IMB was not valid"),
            MailPhase = mailPhase,
        };
    }
}

public class ScanResult
{
    public required string Imb { get; set; }

    public required float MailPhase { get; set; }
}

public static class MailPhase
{
    public static Dictionary<string, float> Steps { get; } = new()
    {
        ["Phase 0 - Origin Processing Cancellation of Postage"] = Phase0,
        ["Phase 1 - Origin Processing"] = Phase1,
        ["Phase 1a - Origin Primary Processing"] = Phase1a,
        ["Phase 1b - Origin Secondary Processing"] = Phase1b,
        ["Phase 2 - Destination Processing"] = Phase2,
        ["Phase 2a - Destination MMP Processing"] = Phase2a,
        ["Phase 2b - Destination SCF Processing"] = Phase2b,
        ["Phase 2c - Destination Primary Processing"] = Phase2c,
        ["Phase 3a - Destination Secondary Processing"] = Phase3a,
        ["Phase 3b - Destination Box Mail Processing"] = Phase3b,
        ["Phase 3c - Destination Sequenced Carrier Sortation"] = Phase3c,
        ["Phase 4c - Delivery"] = Phase4c,
        ["PARS Processing"] = PARSProcessing,
        ["FPARS Processing"] = FPARSProcessing,
        ["Miscellaenous"] = Miscellaenous,
        ["Foreign Processing"] = ForeignProcessing,
    };

    [Description("Phase 0 - Origin Processing Cancellation of Postage")]
    public const float Phase0 = 0;

    [Description("Phase 1 - Origin Processing")]
    public const float Phase1 = 1;

    [Description("Phase 1a - Origin Primary Processing")]
    public const float Phase1a = 1.1F;

    [Description("Phase 1b - Origin Secondary Processing")]
    public const float Phase1b = 1.2F;

    [Description("Phase 2 - Destination Processing")]
    public const float Phase2 = 2;

    [Description("Phase 2a - Destination MMP Processing")]
    public const float Phase2a = 2.1F;

    [Description("Phase 2b - Destination SCF Processing")]
    public const float Phase2b = 2.2F;

    [Description("Phase 2c - Destination Primary Processing")]
    public const float Phase2c = 2.3F;

    [Description("Phase 3a - Destination Secondary Processing")]
    public const float Phase3a = 3.1F;

    [Description("Phase 3b - Destination Box Mail Processing")]
    public const float Phase3b = 3.2F;

    [Description("Phase 3c - Destination Sequenced Carrier Sortation")]
    public const float Phase3c = 3.3F;

    [Description("Phase 4c - Delivery")]
    public const float Phase4c = 3.3F;

    [Description("PARS Processing")]
    public const float PARSProcessing = 10;

    [Description("FPARS Processing")]
    public const float FPARSProcessing = 11;

    [Description("Miscellaenous")]
    public const float Miscellaenous = 12;

    [Description("Foreign Processing")]
    public const float ForeignProcessing = 13;
}

