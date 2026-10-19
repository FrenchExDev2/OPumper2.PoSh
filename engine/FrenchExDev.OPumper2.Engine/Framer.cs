using System;
using System.Collections.Generic;
using System.Text;

namespace FrenchExDev.OPumper2.Engine;

/// <summary>Frames the decoded text of one stream: a delimiter ends a record, a record spanning several reads grows in
/// place, and a record longer than the limit is counted as lost instead of delivered. A line feed record loses the
/// carriage return that ends it; the trailing record of a stream is delivered as written.</summary>
public sealed class Framer
{
    private readonly StringBuilder pending = new();
    private readonly string stream;
    private readonly char delimiter;
    private readonly int maxRecordCharacters;
    private readonly RecordCounter counter;
    private bool oversized;

    public Framer(string stream, char delimiter, int maxRecordCharacters, RecordCounter counter)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentNullException.ThrowIfNull(counter);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxRecordCharacters, 1);
        this.stream = stream;
        this.delimiter = delimiter;
        this.maxRecordCharacters = maxRecordCharacters;
        this.counter = counter;
    }

    /// <summary>The records of a whole text: every delimited record, then the trailing one.</summary>
    public static List<Record> Frame(string text, string stream, char delimiter, int maxRecordCharacters, RecordCounter counter)
    {
        ArgumentNullException.ThrowIfNull(text);
        var framer = new Framer(stream, delimiter, maxRecordCharacters, counter);
        var records = new List<Record>();
        framer.Push(text, records);
        framer.End(records);
        return records;
    }

    /// <summary>Adds the records that <paramref name="text"/> completes; its unterminated end waits for the next text.</summary>
    public void Push(ReadOnlySpan<char> text, ICollection<Record> output)
    {
        ArgumentNullException.ThrowIfNull(output);
        while (true)
        {
            int index = text.IndexOf(delimiter);
            ReadOnlySpan<char> segment = index < 0 ? text : text[..index];
            if (!oversized && pending.Length + segment.Length > maxRecordCharacters)
            {
                pending.Clear();
                oversized = true;
            }
            if (index < 0)
            {
                if (!oversized)
                {
                    pending.Append(segment);
                }
                return;
            }
            if (oversized)
            {
                Lose();
            }
            else
            {
                string frame = pending.Append(segment).ToString();
                pending.Clear();
                if (delimiter == '\n' && frame.EndsWith('\r'))
                {
                    frame = frame[..^1];
                }
                Deliver(frame, output);
            }
            text = text[(index + 1)..];
        }
    }

    /// <summary>Adds the trailing record of the stream, if any.</summary>
    public void End(ICollection<Record> output)
    {
        ArgumentNullException.ThrowIfNull(output);
        if (oversized)
        {
            Lose();
        }
        else if (pending.Length > 0)
        {
            Deliver(pending.ToString(), output);
            pending.Clear();
        }
    }

    private void Lose()
    {
        counter.Sequence++;
        counter.Lost++;
        oversized = false;
    }

    private void Deliver(string frame, ICollection<Record> output)
    {
        counter.Sequence++;
        output.Add(new Record(stream, frame, counter.Sequence));
    }
}
