using System;
using System.IO;

namespace FrenchExDev.OPumper2.Engine;

/// <summary>What the capture of one native stream holds: its spool file (also when it could not be opened, for the caller
/// to delete), whether it was opened, whether it kept every byte, and how many bytes the stream carried.</summary>
public sealed record NativeCapture(string Name, string? Path, bool Spooled, bool CaptureComplete, long Bytes);

/// <summary>The capture of one native stream while it is read: a spool that could not be opened, or that failed once,
/// leaves the capture incomplete; bytes are still counted.</summary>
internal sealed class CaptureSpool
{
    private readonly Stream? spool;
    private readonly string? path;
    private bool complete;
    private long bytes;

    public CaptureSpool(string name, Stream? spool, string? path)
    {
        Name = name;
        this.spool = spool;
        this.path = path;
        complete = spool is not null;
    }

    public string Name { get; }

    public bool Ended { get; set; }

    public NativeCapture Snapshot() => new(Name, path, spool is not null, complete, bytes);

    public void Write(byte[] buffer, int count)
    {
        bytes += count;
        // A failed spool is not written again: its capture stays incomplete.
        if (complete)
        {
            try
            {
                spool!.Write(buffer, 0, count);
            }
#pragma warning disable CA1031 // Any spool failure only makes the capture incomplete; the run goes on.
            catch (Exception)
#pragma warning restore CA1031
            {
                complete = false;
            }
        }
    }

    public void Close() => spool?.Dispose();
}
