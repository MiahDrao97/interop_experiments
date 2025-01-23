// #define SIMPLE_CLI_TESTING
#if SIMPLE_CLI_TESTING
using System.Diagnostics;
#endif

namespace InteropExperiments;

internal static class Program
{
    internal static void Main(string[] args)
    {
        if (args.Length < 1)
        {
            throw new InvalidOperationException("Missing 1 required argument: A file path to a json-formatted IV MTR feed.");
        }

#if SIMPLE_CLI_TESTING
        int? count = null;
        if (args.Length == 3 && args[1] == "--count" && int.TryParse(args[2], out int parsedCount))
        {
            count = parsedCount;
        }

        long csOpenTimeMs;
        long csElapsedMs;
        double csAvg;
        int csidx = 0;
        Stopwatch csharpStopwatch = Stopwatch.StartNew();
        using CsharpIvMtrFeeder csharpReader = CsharpIvMtrFeeder.OpenFile(args[0]);
        {
            csOpenTimeMs = csharpStopwatch.ElapsedMilliseconds;

            csElapsedMs = csharpStopwatch.ElapsedMilliseconds;
            try
            {
                if (count != 0)
                {
                    csharpStopwatch.Restart();
                    foreach (ScanResult scan in csharpReader)
                    {
                        Console.WriteLine($"Read scan[{csidx}] in {csharpStopwatch.ElapsedMilliseconds}ms. IMB: {scan.Imb}, MailPhase: {scan.MailPhase}");
                        csidx++;
                        if (count.HasValue)
                        {
                            if (csidx >= count)
                            {
                                break;
                            }
                        }
                        csElapsedMs += csharpStopwatch.ElapsedMilliseconds;
                        csharpStopwatch.Restart();
                    }
                }
            }
            finally
            {
                csAvg = csElapsedMs / (csidx == 0 ? 1 : csidx);
            }
        }

        Thread.Sleep(1000);

        long zigOpenTimeMs;
        long zigElapsedMs;
        double zigAvg;
        int zidx = 0;
        Stopwatch zigStopwatch = Stopwatch.StartNew();
        using ZigIvMtrFeedReader zigReader = ZigIvMtrFeedReader.OpenFile(args[0]);
        {
            zigOpenTimeMs = zigStopwatch.ElapsedMilliseconds;

            zigElapsedMs = zigStopwatch.ElapsedMilliseconds;
            try
            {
                if (count != 0)
                {
                    zigStopwatch.Restart();
                    foreach (ScanResult scan in zigReader)
                    {
                        Console.WriteLine($"Read scan[{zidx}] in {zigStopwatch.ElapsedMilliseconds}ms. IMB: {scan.Imb}, MailPhase: {scan.MailPhase}");
                        zidx++;
                        if (count.HasValue)
                        {
                            if (zidx >= count)
                            {
                                break;
                            }
                        }
                        zigElapsedMs += zigStopwatch.ElapsedMilliseconds;
                        zigStopwatch.Restart();
                    }
                }
            }
            finally
            {
                zigAvg = zigElapsedMs / (zidx == 0 ? 1 : zidx);
            }
        }

        Console.WriteLine("------------------------------------------------------------------------------------");
        Console.WriteLine($"Opened C# reader in {csOpenTimeMs}ms");
        Console.WriteLine($"C# total time: {csElapsedMs}ms. Processed: {csidx} Avg processing time: {csAvg}ms");
        Console.WriteLine($"Opened zig reader in {zigOpenTimeMs}ms");
        Console.WriteLine($"Zig total time: {zigElapsedMs}ms. Processed: {zidx} Avg processing time: {zigAvg}ms");
#else
        Benchmarks benchmarks = new(args[0], [1000, 10000, 20000, 40000]);
        benchmarks.Run();
#endif
    }
}

