using System.Diagnostics;
using System.Numerics;

namespace InteropExperiments;

public class Benchmarks
{
    private readonly string _filePath;
    private readonly Dictionary<int, Stats<double>> _zigDurations;
    private readonly Dictionary<int, Stats<double>> _csharpDurations;
    private readonly Stats<double> _zigOpenFileDurations;
    private readonly Stats<double> _csharpOpenFileDurations;
    private readonly int[] _counts;

    public Benchmarks(string filePath, int[] counts)
    {
        _filePath = filePath;
        _zigDurations = [];
        _csharpDurations = [];
        _counts = counts;

        foreach (int x in counts)
        {
            _zigDurations.TryAdd(x, new Stats<double>($"Zig_IV_MTR_Reading({x})"));
        }
        _zigOpenFileDurations = new Stats<double>("Zig_Open_IV_MTR");

        foreach (int y in counts)
        {
            _csharpDurations.TryAdd(y, new Stats<double>($"Csharp_IV_MTR_Reading({y})"));
        }
        _csharpOpenFileDurations = new Stats<double>("Csharp_Open_IV_MTR");
    }

    public void Run()
    {
        try
        {
            for (int i = 0; i < 20; i++)
            {
                foreach (int count in _counts)
                {
                    RunZigIvMtrReader(count);
                    RunCsharpIvMtrReader(count);
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to perform benchmarks: {ex.Message} -> {ex.StackTrace}");
            throw;
        }

        Console.WriteLine();
        Console.WriteLine("Zig Open File Duration (ms):");
        Console.WriteLine(" --------------------------------------------------");
        Console.WriteLine("|       Med |        Avg |        Min |        Max |");
        Console.WriteLine(" --------------------------------------------------");
        Console.WriteLine($"| {_zigOpenFileDurations.Median():F6} | {_zigOpenFileDurations.Avg():F6} | {_zigOpenFileDurations.Min():F6} | {_zigOpenFileDurations.Max():F6} |");
        Console.WriteLine(" --------------------------------------------------");
        Console.WriteLine();

        foreach (KeyValuePair<int, Stats<double>> stat in _zigDurations)
        {
            Console.WriteLine($"Zig Total Scan Duration of {stat.Key} Scans (ms):");
            Console.WriteLine(" --------------------------------------------------");
            Console.WriteLine("|       Med |        Avg |        Min |        Max |");
            Console.WriteLine(" --------------------------------------------------");
            Console.WriteLine($"| {stat.Value.Median():F6} | {stat.Value.Avg():F6} | {stat.Value.Min():F6} | {stat.Value.Max():F6} |");
            Console.WriteLine(" --------------------------------------------------");
        }
        Console.WriteLine();
        Console.WriteLine("***************************************");


        Console.WriteLine("C# Open File Duration (ms):");
        Console.WriteLine(" --------------------------------------------------");
        Console.WriteLine("|       Med |        Avg |        Min |        Max |");
        Console.WriteLine(" --------------------------------------------------");
        Console.WriteLine($"| {_csharpOpenFileDurations.Median():F6} | {_csharpOpenFileDurations.Avg():F6} | {_csharpOpenFileDurations.Min():F6} | {_csharpOpenFileDurations.Max():F6} |");
        Console.WriteLine(" --------------------------------------------------");
        Console.WriteLine();

        foreach (KeyValuePair<int, Stats<double>> stat in _csharpDurations)
        {
            Console.WriteLine($"C# Total Scan Duration of {stat.Key} Scans (ms):");
            Console.WriteLine(" --------------------------------------------------");
            Console.WriteLine("|       Med |        Avg |        Min |        Max |");
            Console.WriteLine(" --------------------------------------------------");
            Console.WriteLine($"| {stat.Value.Median():F6} | {stat.Value.Avg():F6} | {stat.Value.Min():F6} | {stat.Value.Max():F6} |");
            Console.WriteLine(" --------------------------------------------------");
        }
        Console.WriteLine();
    }

    private void RunZigIvMtrReader(int count)
    {
        int idx = 1;
        Stopwatch sw = Stopwatch.StartNew();
        using ZigIvMtrFeedReader reader = ZigIvMtrFeedReader.OpenFile(_filePath);
        _zigOpenFileDurations.Record(GetElapsedMilliseconds(sw));
        foreach (ScanResult _ in reader)
        {
            if (idx == count)
            {
                break;
            }
            idx++;
        }
        _zigDurations[count].Record(GetElapsedMilliseconds(sw));
    }

    private void RunCsharpIvMtrReader(int count)
    {
        int idx = 1;
        Stopwatch sw = Stopwatch.StartNew();
        using CsharpIvMtrFeeder reader = CsharpIvMtrFeeder.OpenFile(_filePath);
        _csharpOpenFileDurations.Record(GetElapsedMilliseconds(sw));
        foreach (ScanResult _ in reader)
        {
            if (idx == count)
            {
                break;
            }
            idx++;
        }
        _csharpDurations[count].Record(GetElapsedMilliseconds(sw));
    }

    private static double GetElapsedMilliseconds(Stopwatch sw)
    {
        return sw.ElapsedTicks / (Stopwatch.Frequency / 1_000);
    }

    private class Stats<T>(string name) where T : notnull, ISignedNumber<T>, IDivisionOperators<T, double, T>
    {
        private readonly List<T> _list = [];

        public string Name { get; } = name;

        public int RunCount => _list.Count;

        public void Record(T amount) => _list.Add(amount);

        public T Avg()
        {
            T sum = T.Zero;
            foreach (T x in _list)
            {
                sum += x;
            }
            return sum / RunCount;
        }

        public T Median() => _list.OrderBy(static x => x).ToArray()[_list.Count / 2];

        public T Max() => _list.Max()!;

        public T Min() => _list.Min()!;
    }
}
