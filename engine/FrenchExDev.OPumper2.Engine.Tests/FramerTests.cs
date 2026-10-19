using System;
using System.Collections.Generic;
using System.Linq;
using Xunit;

namespace FrenchExDev.OPumper2.Engine.Tests;

public sealed class FramerTests
{
    private static string Texts(IEnumerable<Record> records) => string.Join("|", records.Select(record => record.Text));

    [Fact]
    public void CombinesSplitRecordsKeepsTheSequenceAndCountsOversizedRecords()
    {
        var counter = new RecordCounter();
        var framer = new Framer("stdout", '\n', 4, counter);
        var records = new List<Record>();
        framer.Push("ab", records);
        framer.Push("c\r\n123456\nx", records);
        framer.End(records);
        Assert.Equal("abc|x", Texts(records));
        Assert.Equal(new long[] { 1, 3 }, records.Select(record => record.Sequence));
        Assert.All(records, record => Assert.Equal("stdout", record.Stream));
        Assert.All(records, record => Assert.False(record.Truncated));
        Assert.Equal(1, counter.Lost);
        framer.Push("12345", records);
        framer.End(records);
        Assert.Equal(2, records.Count);
        Assert.Equal(2, counter.Lost);
        Assert.Equal(4, counter.Sequence);
    }

    [Fact]
    public void PreservesEmptyAndMaximumLengthRecords()
    {
        var counter = new RecordCounter();
        var records = Framer.Frame("\0x\0y", "stderr", '\0', 1, counter);
        Assert.Equal("|x|y", Texts(records));
        Assert.Equal(new long[] { 1, 2, 3 }, records.Select(record => record.Sequence));
        Assert.Equal(0, counter.Lost);
    }

    [Fact]
    public void RemovesOnlyTheCarriageReturnThatEndsALineFeedRecord()
    {
        var counter = new RecordCounter();
        Assert.Equal("plain|windows", Texts(Framer.Frame("plain\nwindows\r\n", "stdout", '\n', 16, counter)));
        Assert.Equal("kept\r", Texts(Framer.Frame("kept\r\0", "stdout", '\0', 16, counter)));
        Assert.Equal("tail\r", Texts(Framer.Frame("tail\r", "stdout", '\n', 16, counter)));
    }

    [Fact]
    public void GrowsARecordAcrossReadsUpToTheInclusiveLimit()
    {
        var counter = new RecordCounter();
        var framer = new Framer("stdout", '\n', 5, counter);
        var records = new List<Record>();
        framer.Push("ab", records);
        framer.Push("cd", records);
        framer.Push("e\n", records);
        framer.Push("ab", records);
        framer.Push("cdef\nlast", records);
        // A record already over the limit stays lost through the reads that end it.
        framer.Push("\n123456", records);
        framer.Push("78\nok", records);
        framer.End(records);
        Assert.Equal("abcde|last|ok", Texts(records));
        Assert.Equal(2, counter.Lost);
        Assert.Equal(5, counter.Sequence);
    }

    [Fact]
    public void LosesAnOversizedTrailingRecordAndDeliversNothingForAnEmptyEnd()
    {
        var counter = new RecordCounter();
        Assert.Empty(Framer.Frame("abcd", "stdout", '\n', 3, counter));
        Assert.Equal(1, counter.Lost);
        Assert.Empty(Framer.Frame(string.Empty, "stdout", '\n', 3, counter));
        Assert.Equal(1, counter.Sequence);
    }

    [Fact]
    public void DeliversTheTrailingRecordOnce()
    {
        var counter = new RecordCounter();
        var framer = new Framer("stdout", '\n', 8, counter);
        var records = new List<Record>();
        framer.Push("tail", records);
        framer.End(records);
        framer.End(records);
        framer.Push("next\n", records);
        Assert.Equal("tail|next", Texts(records));
        Assert.Equal(2, counter.Sequence);
    }

    [Fact]
    public void SharesOneSequenceAcrossTheStreamsOfACall()
    {
        var counter = new RecordCounter();
        Framer.Frame("a\nb\n", "stdout", '\n', 8, counter);
        var errors = Framer.Frame("c", "stderr", '\n', 8, counter);
        Assert.Equal(3, errors.Single().Sequence);
        Assert.Equal("stderr", errors.Single().Stream);
    }

    [Fact]
    public void RefusesMissingArgumentsAndAnEmptyLimit()
    {
        var counter = new RecordCounter();
        Assert.Throws<ArgumentNullException>(() => new Framer(null!, '\n', 1, counter));
        Assert.Throws<ArgumentNullException>(() => new Framer("stdout", '\n', 1, null!));
        Assert.Throws<ArgumentOutOfRangeException>(() => new Framer("stdout", '\n', 0, counter));
        Assert.Throws<ArgumentNullException>(() => Framer.Frame(null!, "stdout", '\n', 1, counter));
        var framer = new Framer("stdout", '\n', 1, counter);
        Assert.Throws<ArgumentNullException>(() => framer.Push("x", null!));
        Assert.Throws<ArgumentNullException>(() => framer.End(null!));
    }

    [Fact]
    public void ComparesRecordsByValue()
    {
        var counter = new RecordCounter();
        Assert.Equal(new[] { new Record("stdout", "a", 1), new Record("stdout", "b", 2) }, Framer.Frame("a\nb", "stdout", '\n', 8, counter));
        var record = new Record("stdout", "text", 1);
        Assert.NotEqual(record, record with { Truncated = true });
        Assert.False(record.Truncated);
    }
}
