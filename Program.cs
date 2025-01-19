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

        using IvMtrFeedReader reader = IvMtrFeedReader.OpenFile(args[0]);

        int idx = 0;
        if (count > 0)
        {
            foreach (ScanResult scan in reader)
            {
                Console.WriteLine($"Read scan[{idx}]. IMB: {scan.Imb}, MailPhase: {scan.MailPhase}");
                idx++;
                if (count.HasValue)
                {
                    if (idx >= count)
                    {
                        break;
                    }
                }
            }
        }
    }
}

