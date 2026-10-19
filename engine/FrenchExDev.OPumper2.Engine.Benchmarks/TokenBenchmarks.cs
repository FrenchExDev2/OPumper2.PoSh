namespace FrenchExDev.OPumper2.Engine.Benchmarks;

using System;
using System.Threading.Tasks;
using BenchmarkDotNet.Attributes;
using Microsoft.ML.Tokenizers;

/// <summary>Counting the tokens of a captured output: whole text synchronously, on a worker, and candidate newline chunking.
/// The candidate is not exact for whitespace/newline runs (TokenizerWarmupTests); it measures cost only.</summary>
[MemoryDiagnoser]
public class TokenBenchmarks
{
    private Tokenizer tokenizer = null!;
    private string text = string.Empty;

    /// <summary>The number of lines counted.</summary>
    [Params(20_000, 200_000)]
    public int Lines { get; set; }

    /// <summary>Both supported packaged tokenizer profiles.</summary>
    [Params("o200k_base", "cl100k_base")]
    public string EncodingName { get; set; } = "o200k_base";

    /// <summary>Writes the output once per parameter value.</summary>
    [GlobalSetup]
    public void Setup()
    {
        tokenizer = TiktokenTokenizer.CreateForEncoding(EncodingName);
        text = Output.Lines(Lines);
    }

    /// <summary>The whole capture counted at once.</summary>
    /// <returns>The token count.</returns>
    [Benchmark(Baseline = true)]
    public int Whole() => tokenizer.CountTokens(text);

    /// <summary>The exact whole-text fallback on a worker, including scheduling and joining it.
    /// This measures offloading alone; production latency would require overlapping independent work.</summary>
    /// <returns>The token count.</returns>
    [Benchmark]
    public int WholeInBackground() => Task.Run(() => tokenizer.CountTokens(text)).GetAwaiter().GetResult();

    /// <summary>The candidate cut in chunks of about 64 KiB. This boundary overcounts some whitespace/newline runs;
    /// similar timing on this corpus does not prove exactness for arbitrary output.</summary>
    /// <returns>The token count.</returns>
    [Benchmark]
    public int Chunked()
    {
        int total = 0;
        ReadOnlySpan<char> rest = text;
        while (rest.Length > 0)
        {
            int end = Cut(rest, 65536);
            total += tokenizer.CountTokens(rest[..end]);
            rest = rest[end..];
        }

        return total;
    }

    private static int Cut(ReadOnlySpan<char> text, int size)
    {
        if (text.Length <= size)
        {
            return text.Length;
        }

        for (int index = size; index < text.Length - 1; index++)
        {
            if (text[index] == '\n' && text[index + 1] != '\n' && text[index + 1] != '\r')
            {
                return index + 1;
            }
        }

        return text.Length;
    }
}
