using System;
using System.Threading.Tasks;
using Microsoft.ML.Tokenizers;
using Xunit;

namespace FrenchExDev.OPumper2.Engine.Tests;

public sealed class TokenizerWarmupTests
{
    [Fact]
    public async Task CreatesTheNamedEncodingOnABackgroundTask()
    {
        Tokenizer tokenizer = await TokenizerWarmup.Start("o200k_base");
        Assert.Equal(TiktokenTokenizer.CreateForEncoding("o200k_base").CountTokens("pump git status"), tokenizer.CountTokens("pump git status"));
        Assert.IsType<TiktokenTokenizer>(tokenizer);
    }

    [Fact]
    public async Task FaultsTheTaskForAnUnknownEncodingAndRefusesNone()
    {
        Task<Tokenizer> unknown = TokenizerWarmup.Start("op2_unknown");
        await Assert.ThrowsAnyAsync<Exception>(() => unknown);
        Assert.True(unknown.IsFaulted);
        // A missing name fails the call itself, before any task starts.
        Assert.Throws<ArgumentNullException>(() => { _ = TokenizerWarmup.Start(null!); });
    }

    [Theory]
    [InlineData("o200k_base")]
    [InlineData("cl100k_base")]
    public async Task RejectsNewlineChunkBoundariesAcrossWhitespaceRuns(string encoding)
    {
        Tokenizer tokenizer = await TokenizerWarmup.Start(encoding);
        // A newline followed by neither CR nor LF is not necessarily a tokenizer boundary. Whitespace can join the
        // following newline in one token; the proposed streaming cut would overcount both supported encodings.
        foreach (string text in new[] { "word\n \nfoo", "a\n\t\nbar", "\n \n", "\n\t\n" })
        {
            int cut = text.IndexOf('\n') + 1;
            int whole = tokenizer.CountTokens(text);
            int chunks = tokenizer.CountTokens(text.AsSpan(0, cut)) + tokenizer.CountTokens(text.AsSpan(cut));
            Assert.Equal(text.Length < 4 ? 1 : 3, whole);
            Assert.Equal(whole + 1, chunks);
        }
    }
}
