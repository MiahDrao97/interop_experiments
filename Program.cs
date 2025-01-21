using System.Diagnostics;

namespace InteropExperiments;

internal static class Program
{
    internal static void Main(string[] args)
    {
        if (args.Length < 1)
        {
            throw new InvalidOperationException("Missing 1 required argument: A file path to a json-formatted IV MTR feed.");
        }

        int? count = null;
        if (args.Length == 3 && args[1] == "--count" && int.TryParse(args[2], out int parsedCount))
        {
            count = parsedCount;
        }

        Stopwatch sw = Stopwatch.StartNew();
        using ZigIvMtrFeedReader reader = ZigIvMtrFeedReader.OpenFile(args[0]);
        Console.WriteLine($"Opened reader in {sw.ElapsedMilliseconds}ms");

        int idx = 0;
        long elapsedMs = sw.ElapsedMilliseconds;
        try
        {
            if (count != 0)
            {
                sw.Restart();
                foreach (ScanResult scan in reader)
                {
                    Console.WriteLine($"Read scan[{idx}] in {sw.ElapsedMilliseconds}ms. IMB: {scan.Imb}, MailPhase: {scan.MailPhase}");
                    idx++;
                    if (count.HasValue)
                    {
                        if (idx >= count)
                        {
                            break;
                        }
                    }
                    elapsedMs += sw.ElapsedMilliseconds;
                    sw.Restart();
                }
            }
        }
        finally
        {
            double avg = elapsedMs / (idx == 0 ? 1 : idx);
            Console.WriteLine($"Total time: {elapsedMs}ms. Processed: {idx} Avg processing time: {avg}ms");
        }
    }
}

