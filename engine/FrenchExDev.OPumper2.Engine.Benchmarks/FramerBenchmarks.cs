namespace FrenchExDev.OPumper2.Engine.Benchmarks;

using System;
using System.Collections.Generic;
using BenchmarkDotNet.Attributes;

/// <summary>Framing a captured output: in one piece (a replay) and in reads of 4096 characters (a live call).</summary>
[MemoryDiagnoser]
public class FramerBenchmarks
{
    private string text = string.Empty;

    /// <summary>The number of lines framed.</summary>
    [Params(20_000, 200_000)]
    public int Lines { get; set; }

    /// <summary>Writes the output once per parameter value.</summary>
    [GlobalSetup]
    public void Setup() => text = Output.Lines(Lines);

    /// <summary>The whole output framed at once, as a replay frames a recall.</summary>
    /// <returns>The number of records.</returns>
    [Benchmark(Baseline = true)]
    public int Whole() => Framer.Frame(text, "stdout", '\n', 65536, new RecordCounter()).Count;

    /// <summary>The output pushed in reads of 4096 characters, as the reader of a live call pushes it.</summary>
    /// <returns>The number of records.</returns>
    [Benchmark]
    public int Reads()
    {
        var framer = new Framer("stdout", '\n', 65536, new RecordCounter());
        var records = new List<Record>(Lines);
        ReadOnlySpan<char> rest = text;
        while (rest.Length > 0)
        {
            int length = Math.Min(4096, rest.Length);
            framer.Push(rest[..length], records);
            rest = rest[length..];
        }

        framer.End(records);
        return records.Count;
    }
}
