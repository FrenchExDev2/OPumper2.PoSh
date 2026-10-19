namespace FrenchExDev.OPumper2.Engine;

/// <summary>One framed record handed to a call's callbacks: its stream, its text and its rank among every record of the
/// call. Delivered records are whole; <see cref="Truncated"/> keeps the shape record callbacks are written against.
/// PowerShell can still assign its init-only properties, as it could on the record objects callbacks used to get.</summary>
public sealed record Record(string Stream, string Text, long Sequence)
{
    public bool Truncated { get; init; }
}

/// <summary>The record accounting of one call, shared by its streams: every framed record takes the next sequence
/// number, and a record longer than the limit is counted as lost instead of delivered.</summary>
public sealed class RecordCounter
{
    public long Sequence { get; internal set; }

    public long Lost { get; internal set; }
}
