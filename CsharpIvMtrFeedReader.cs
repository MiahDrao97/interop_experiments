using System.Collections;
using System.Text;
using Newtonsoft.Json;

namespace InteropExperiments;

public sealed class CsharpIvMtrFeeder : IIvMtrFeedReader
{
    private readonly FileStream _fileStream;
    private bool _disposed;

    private CsharpIvMtrFeeder(FileStream file)
    {
        _fileStream = file;
    }

    ~CsharpIvMtrFeeder()
    {
        _fileStream.Close();
    }

    public static CsharpIvMtrFeeder OpenFile(string filePath)
    {
        return new(File.OpenRead(filePath));
    }

    public IEnumerator<ScanResult> GetEnumerator()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return new Enumerator(_fileStream);
    }

    IEnumerator IEnumerable.GetEnumerator()
    {
        return GetEnumerator();
    }

    public void Dispose()
    {
        _fileStream.Dispose();
        GC.SuppressFinalize(this);
        _disposed = true;
    }

    private struct Enumerator(FileStream fileStream) : IEnumerator<ScanResult>
    {
        private readonly FileStream _stream = fileStream;
        private bool _openEvents;

        public bool MoveNext()
        {
            if (GetNext() is ScanResult scan)
            {
                Current = scan;
                return true;
            }
            return false;
        }

        public ScanResult Current { get; private set; } = null!;

        readonly object IEnumerator.Current => Current;

        public readonly void Dispose() { }

        public void Reset()
        {
            throw new NotSupportedException($"Resetting is not supported. Instead dispose the current instance of {nameof(CsharpIvMtrFeeder)} and open a new file.");
        }

        private ScanResult? GetNext()
        {
            if (!_openEvents)
            {
                return OpenEvents();
            }
            else
            {
                return ParseObject();
            }
        }

        private ScanResult? OpenEvents()
        {
            ReadOnlySpan<char> eventsKey = "events";
            bool insideQuotes = false;
            bool insideEvents = false;
            int i = 0;
            while (true)
            {
                int nextByte = _stream.ReadByte();
                if (nextByte < 1)
                {
                    // end of stream
                    break;
                }
                if (!insideQuotes && char.IsWhiteSpace((char)nextByte))
                {
                    continue;
                }
                if ((char)nextByte == '"')
                {
                    insideQuotes = !insideQuotes;
                }
                if (insideQuotes)
                {
                    if (i < eventsKey.Length)
                    {
                        if (eventsKey[i] == (char)nextByte)
                        {
                            i++;
                            if (i == eventsKey.Length)
                            {
                                insideEvents = true;
                            }
                        }
                        else
                        {
                            i = 0;
                        }
                    }
                }

                if (!insideQuotes && insideEvents && (char)nextByte == ':')
                {
                    return OpenArray();
                }
            }
            return null;
        }

        private ScanResult? OpenArray()
        {
            while (true)
            {
                int nextByte = _stream.ReadByte();
                if ((char)nextByte == '[')
                {
                    break;
                }
                else if (nextByte < 0)
                {
                    // nothing here
                    return null;
                }
                else if (char.IsWhiteSpace((char)nextByte))
                {
                    continue;
                }
                else
                {
                    // invalid: first non-whitespace character must be open square bracket
                    throw new InvalidOperationException($"First non-whitespace character is not an open square bracket. Expecting a JSON file that's a json array of objects.");
                }
            }

            _openEvents = true;
            return GetNext();
        }

        private readonly ScanResult? ParseObject()
        {
            Span<byte> buf = stackalloc byte[4096];

            bool insideQuotes = false;
            bool openBrace = false;
            bool closingBrace = false;
            int i = 0;
            while (i < 4096)
            {
                int nextByte = _stream.ReadByte();
                if (nextByte < 1)
                {
                    // end of stream
                    break;
                }
                if (i == 0 && (char)nextByte == ']')
                {
                    // we're at the end
                    return null;
                }
                if (!insideQuotes && char.IsWhiteSpace((char)nextByte))
                {
                    continue;
                }
                if (i == 0 && (char)nextByte == ',')
                {
                    continue;
                }
                if ((char)nextByte == '"')
                {
                    insideQuotes = !insideQuotes;
                }

                if (!openBrace && (char)nextByte == '{')
                {
                    openBrace = true;
                    buf[i] = (byte)nextByte;
                }
                else if (openBrace)
                {
                    buf[i] = (byte)nextByte;

                    if ((char)nextByte == '}')
                    {
                        closingBrace = true;
                        break;
                    }
                }
                else
                {
                    buf[i] = (byte)nextByte;
                    string parsed = Encoding.UTF8.GetString(buf);
                    throw new InvalidOperationException($"Invalid object encountered: '{parsed}'");
                }

                i++;
            }

            if (!closingBrace)
            {
                string parsed = Encoding.UTF8.GetString(buf);
                throw new InvalidOperationException($"JSON object not terminated with a closing brace: '{parsed}'");
            }

            string obj = Encoding.UTF8.GetString(buf);
            ScanJson json = JsonConvert.DeserializeObject<ScanJson>(obj)
                ?? throw new InvalidOperationException($"Unable to deserialize type {typeof(ScanJson)} from string '{obj}'");

            string mailPhaseStr = json.MailPhase ?? throw new InvalidOperationException($"JSON object did not have a 'mailPhase' field: '{obj}'");
            return new ScanResult
            {
                Imb = json.Imb ?? throw new InvalidOperationException($"JSON object did not have an 'imb' field: '{obj}'"),
                MailPhase = (MailPhase)mailPhaseStr,
            };
        }

        private class ScanJson
        {
            [JsonProperty("imb")]
            public string? Imb { get; set; }

            [JsonProperty("mailPhase")]
            public string? MailPhase { get; set; }
        }
    }
}
