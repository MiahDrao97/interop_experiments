namespace InteropExperiments;

/// <summary>
/// Reads an IV-MTR feed. Each scan is lazily read from the underlying file.
/// </summary>
/// <remarks>
/// Dispose after use to free unmanaged memory.
/// </remarks>
public interface IIvMtrFeedReader : IEnumerable<ScanResult>, IDisposable
{ }
