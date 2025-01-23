using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace InteropExperiments;

public class Benchmarks
{
    private static readonly Meter _meter = new("IV_MTR_FileFeed");

    private readonly string _filePath;
    private readonly Dictionary<int, Histogram<double>> _zigDurations;
    private readonly Dictionary<int, Histogram<double>> _csharpDurations;
    private readonly Histogram<double> _zigOpenFileDurations;
    private readonly Histogram<double> _csharpOpenFileDurations;
    private readonly int[] _counts;

    public Benchmarks(string filePath, int[] counts)
    {
        _filePath = filePath;
        _zigDurations = [];
        _csharpDurations = [];
        _counts = counts;

        foreach (int x in counts)
        {
            _zigDurations.TryAdd(x, CreateHistogram($"Zig_IV_MTR_Reading({x})"));
        }
        _zigOpenFileDurations = CreateHistogram("Zig_Open_IV_MTR");

        foreach (int y in counts)
        {
            _csharpDurations.TryAdd(y, CreateHistogram($"Csharp_IV_MTR_Reading({y})"));
        }
        _csharpOpenFileDurations = CreateHistogram("Csharp_Open_IV_MTR");
    }

    public void Run()
    {
        for (int i = 0; i < 20; i++)
        {
            foreach (int count in _counts)
            {
                RunZigIvMtrReader(count);
                RunCsharpIvMtrReader(count);
            }
        }

        Console.WriteLine("----------------------------------------------------------");
        // TODO : Format report
    }

    private void RunZigIvMtrReader(int count)
    {
        int idx = 1;
        Stopwatch sw = Stopwatch.StartNew();
        using ZigIvMtrFeedReader reader = ZigIvMtrFeedReader.OpenFile(_filePath);
        _zigOpenFileDurations.Record(GetElapsedMicroseconds(sw));
        foreach (ScanResult _ in reader)
        {
            if (idx == count)
            {
                break;
            }
            idx++;
        }
    }

    private void RunCsharpIvMtrReader(int count)
    {
        int idx = 1;
        Stopwatch sw = Stopwatch.StartNew();
        using CsharpIvMtrFeeder reader = CsharpIvMtrFeeder.OpenFile(_filePath);
        _csharpOpenFileDurations.Record(GetElapsedMicroseconds(sw));
        foreach (ScanResult _ in reader)
        {
            if (idx == count)
            {
                break;
            }
            idx++;
        }
    }

    private static double GetElapsedMicroseconds(Stopwatch sw)
    {
        return sw.ElapsedTicks / (Stopwatch.Frequency / 1_000_000);
    }

    private static Histogram<double> CreateHistogram(string name)
    {
        return _meter.CreateHistogram<double>(name, "Microseconds");
    }
}
