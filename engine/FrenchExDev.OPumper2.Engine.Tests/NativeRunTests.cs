using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using Xunit;

namespace FrenchExDev.OPumper2.Engine.Tests;

// Children are pwsh processes, the shell this engine runs in; each test owns its spool files.
public sealed class NativeRunTests : IDisposable
{
    private static readonly Encoding Strict = new UTF8Encoding(false, throwOnInvalidBytes: true);
    private static readonly string[] ClosingShell = ["-c", "exec 1>&- 2>&-; sleep 1.5"];
    private static readonly string[] ClosingInput = ["-c", "exec 0<&-; sleep 5"];
    private readonly string folder = Path.Combine(Path.GetTempPath(), "opumper2-engine-" + Guid.NewGuid().ToString("N"));

    public NativeRunTests() => Directory.CreateDirectory(folder);

    public void Dispose() => Directory.Delete(folder, recursive: true);

    private static ProcessStartInfo Child(string code, bool input = false)
    {
        var info = new ProcessStartInfo("pwsh") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input };
        if (input)
        {
            info.StandardInputEncoding = new UTF8Encoding(false);
        }
        foreach (string argument in new[] { "-NoProfile", "-NonInteractive", "-Command", "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);" + code })
        {
            info.ArgumentList.Add(argument);
        }
        return info;
    }

    private string SpoolPath(string name) => Path.Combine(folder, name + ".spool");

    private NativeRun Start(ProcessStartInfo info, string? input = null, int bufferSize = 8192, int maxRecordCharacters = 65536)
    {
        var run = new NativeRun(info, Strict, '\n', '\n', maxRecordCharacters, input, new RecordCounter(), bufferSize);
        Assert.True(run.Start());
        run.Read(File.OpenWrite(SpoolPath("stdout")), SpoolPath("stdout"), File.OpenWrite(SpoolPath("stderr")), SpoolPath("stderr"));
        return run;
    }

    private static List<Record> Drain(NativeRun run)
    {
        var records = new List<Record>();
        var watch = Stopwatch.StartNew();
        while (!run.IsComplete)
        {
            Assert.True(watch.Elapsed.TotalSeconds < 60, "The run did not complete.");
            records.AddRange(run.Next(50));
        }
        return records;
    }

    private static string Texts(IEnumerable<Record> records, string stream) => string.Join("|", records.Where(record => record.Stream == stream).Select(record => record.Text));

    [Fact]
    public void FramesBothStreamsCapturesEveryByteAndCountsThem()
    {
        using var unread = new NativeRun(Child("exit"), Strict, '\n', '\n', 1, null, new RecordCounter());
        Assert.Null(unread.Stdout);
        Assert.Null(unread.Stderr);
        using NativeRun run = Start(Child("[Console]::Out.Write(\"abc`nlast\"); [Console]::Error.Write(\"xyz`r`n\")"));
        List<Record> records = Drain(run);
        Assert.Equal("abc|last", Texts(records, "stdout"));
        Assert.Equal("xyz", Texts(records, "stderr"));
        Assert.Equal(3, run.Counter.Sequence);
        Assert.Equal(new long[] { 1, 2, 3 }, records.Select(record => record.Sequence).Order());
        Assert.Equal(0, run.Process.ExitCode);
        run.Kill();
        run.Dispose();
        Assert.Equal(new NativeCapture("stdout", SpoolPath("stdout"), true, true, 8), run.Stdout);
        Assert.Equal(new NativeCapture("stderr", SpoolPath("stderr"), true, true, 5), run.Stderr);
        Assert.Equal("abc\nlast", File.ReadAllText(SpoolPath("stdout")));
        Assert.Equal("xyz\r\n", File.ReadAllText(SpoolPath("stderr")));
    }

    [Fact]
    public void RunsTheChildWithExactlyTheEnvironmentOfItsStartInfo()
    {
        // The engine reads no environment itself: the PowerShell layer sets and removes the child's variables on the
        // start info (pump -Environment), and the child gets those, not the engine's process environment.
        string inherited = "OP2_ENGINE_INHERITED_" + Guid.NewGuid().ToString("N");
        Environment.SetEnvironmentVariable(inherited, "parent");
        try
        {
            ProcessStartInfo info = Child($"[Console]::Out.Write(\"$env:OP2_ENGINE_SET|$env:{inherited}|\")");
            info.Environment["OP2_ENGINE_SET"] = "child";
            Assert.True(info.Environment.Remove(inherited));
            using NativeRun run = Start(info);
            Assert.Equal("child||", Texts(Drain(run), "stdout"));
        }
        finally
        {
            Environment.SetEnvironmentVariable(inherited, null);
        }
    }

    [Fact]
    public void WritesItsInputTextToTheChildAndClosesIt()
    {
        using NativeRun run = Start(Child("[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::Out.Write([Console]::In.ReadToEnd())", input: true), "café\nend");
        Assert.Equal("café|end", Texts(Drain(run), "stdout"));
    }

    [Fact]
    public void DecodesCharactersSplitAcrossReads()
    {
        using NativeRun run = Start(Child("[Console]::Out.Write(\"é€`n\")"), bufferSize: 1);
        Assert.Equal("é€", Texts(Drain(run), "stdout"));
        // é takes two bytes, € three, the line feed one: every read carried a single byte.
        Assert.Equal(6, run.Stdout!.Bytes);
    }

    [Fact]
    public void ThrowsAnInvalidByteOnceTheRecordsBeforeItWereTaken()
    {
        using NativeRun run = Start(Child("$o=[Console]::OpenStandardOutput(); $b=[Text.Encoding]::UTF8.GetBytes(\"ok`n\"); $o.Write($b,0,$b.Length); $o.Flush(); Start-Sleep -Milliseconds 300; $o.WriteByte(255); $o.Flush()"));
        var records = new List<Record>();
        var watch = Stopwatch.StartNew();
        Assert.Throws<DecoderFallbackException>(() =>
        {
            while (watch.Elapsed.TotalSeconds < 60)
            {
                records.AddRange(run.Next(50));
            }
        });
        Assert.Equal("ok", Texts(records, "stdout"));
        Assert.False(run.IsComplete);
    }

    [Fact]
    public void RejectsAnIncompleteCharacterAtTheEndOfAStream()
    {
        using NativeRun run = Start(Child("Start-Sleep -Milliseconds 500; $o=[Console]::OpenStandardOutput(); $o.WriteByte(195); $o.Flush()"));
        // The failure arrives while the call waits: the wait returns, and the next call throws.
        Assert.Empty(run.Next(30000));
        Assert.Throws<DecoderFallbackException>(() => run.Next(50));
    }

    [Fact]
    public void LeavesACaptureIncompleteWhenItsSpoolFailsOrIsMissing()
    {
        var broken = new MemoryStream();
        broken.Dispose();
        using var run = new NativeRun(Child("[Console]::Out.Write(\"a`n\"); [Console]::Error.Write('b')"), Strict, '\n', '\n', 16, null, new RecordCounter());
        Assert.True(run.Start());
        run.Read(broken, "broken", null, null);
        List<Record> records = Drain(run);
        Assert.Equal("a", Texts(records, "stdout"));
        Assert.Equal("b", Texts(records, "stderr"));
        Assert.Equal(new NativeCapture("stdout", "broken", true, false, 2), run.Stdout);
        Assert.Equal(new NativeCapture("stderr", null, false, false, 1), run.Stderr);
    }

    [Fact]
    public void BoundsAnIdleWaitThenKillsTheWholeTree()
    {
        // The grandchild inherits the output streams: killing the child alone would leave them open.
        using NativeRun run = Start(Child("$p = Start-Process pwsh -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 60' -NoNewWindow -PassThru; [Console]::Out.Write(\"$($p.Id)`n\"); Start-Sleep -Seconds 60"));
        var watch = Stopwatch.StartNew();
        Record[] started = run.Next(200);
        while (started.Length == 0)
        {
            Assert.True(watch.Elapsed.TotalSeconds < 60, "The grandchild did not start.");
            started = run.Next(200);
        }
        using Process grandchild = Process.GetProcessById(int.Parse(started.Single().Text, System.Globalization.CultureInfo.InvariantCulture));
        watch.Restart();
        Assert.Empty(run.Next(200));
        Assert.True(watch.Elapsed.TotalSeconds < 10);
        // A running child has no elapsed time yet.
        Assert.Null(run.ProcessElapsed);
        run.Kill();
        Assert.Empty(Drain(run));
        Assert.True(run.Process.HasExited);
        Assert.True(grandchild.WaitForExit(10000));
        Assert.False(run.Abandoned);
    }

    [Fact]
    public void AbandonsStreamsHeldOpen()
    {
        using NativeRun run = Start(Child("Start-Sleep -Seconds 60"));
        run.Abandon();
        Assert.True(run.Abandoned);
        Assert.True(run.IsComplete);
        // The first call waits for the queue to complete; the next one returns at once, without waiting for an exit.
        Assert.Empty(run.Next(30000));
        var watch = Stopwatch.StartNew();
        Assert.Empty(run.Next(30000));
        Assert.True(watch.Elapsed.TotalSeconds < 10);
        run.Kill();
    }

    [Fact]
    public void WaitsForTheChildToExitOnceItsStreamsEnded()
    {
        ProcessStartInfo info = OperatingSystem.IsWindows()
            ? Child("Add-Type -Namespace OP2 -Name Std -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern IntPtr GetStdHandle(int n); [DllImport(\"kernel32.dll\")] public static extern bool CloseHandle(IntPtr h);'; [void][OP2.Std]::CloseHandle([OP2.Std]::GetStdHandle(-11)); [void][OP2.Std]::CloseHandle([OP2.Std]::GetStdHandle(-12)); Start-Sleep -Milliseconds 1500")
            : new ProcessStartInfo("sh", ClosingShell) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        // Both streams end long before the child exits: the run completes only once it has exited, and each call waits
        // for that exit instead of returning at once.
        using NativeRun run = Start(info);
        int calls = 0;
        while (!run.IsComplete)
        {
            calls++;
            Assert.Empty(run.Next(50));
        }
        Assert.True(run.Process.HasExited);
        Assert.InRange(calls, 1, 2000);
    }

    [Fact]
    public void ReturnsTheRecordsThatArriveWhileItWaits()
    {
        using NativeRun run = Start(Child("Start-Sleep -Milliseconds 500; [Console]::Out.Write(\"late`n\"); [Console]::Out.Flush(); Start-Sleep -Seconds 2"));
        Assert.Equal("late", Texts(run.Next(30000), "stdout"));
        run.Kill();
        Drain(run);
    }

    [Fact]
    public void AbandonsAndReleasesARunDisposedWhileItsChildRuns()
    {
        var run = Start(Child("Start-Sleep -Seconds 60"));
        int id = run.Process.Id;
        run.Dispose();
        Assert.True(run.Abandoned);
        Assert.Throws<InvalidOperationException>(() => run.Process.Id);
        Assert.Throws<ObjectDisposedException>(run.Abandon);
        Process.GetProcessById(id).Kill(entireProcessTree: true);
    }

    [Fact]
    public void FailsTheRunWhenTheChildClosesItsInputBeforeReadingIt()
    {
        ProcessStartInfo info = OperatingSystem.IsWindows()
            ? Child("Add-Type -Namespace OP2 -Name In -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern IntPtr GetStdHandle(int n); [DllImport(\"kernel32.dll\")] public static extern bool CloseHandle(IntPtr h);'; [void][OP2.In]::CloseHandle([OP2.In]::GetStdHandle(-10)); Start-Sleep -Seconds 5", input: true)
            : new ProcessStartInfo("sh", ClosingInput) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        using NativeRun run = Start(info, input: new string('x', 4 * 1024 * 1024));
        var watch = Stopwatch.StartNew();
        Assert.ThrowsAny<IOException>(() =>
        {
            while (watch.Elapsed.TotalSeconds < 60)
            {
                run.Next(50);
            }
        });
        run.Kill();
    }

    [Fact]
    public void SlowsTheChildDownWhenRecordsAreNotTakenAndAbandonsABlockedRead()
    {
        var clock = new SteppingClock();
        using var run = new NativeRun(Child("$line = ('x' * 1023) + \"`n\"; foreach ($i in 1..65536) { [Console]::Out.Write($line) }"),
            Strict, '\n', '\n', 65536, null, new RecordCounter(), timeProvider: clock);
        Assert.True(run.Start());
        run.Read(null, null, null, null);
        // The first clock read starts the child; the second starts its first wait on a full queue. Waiting for that
        // event, rather than sleeping from process start, excludes the child's variable startup time under load.
        Assert.True(System.Threading.SpinWait.SpinUntil(() => clock.Reads >= 2, TimeSpan.FromSeconds(30)), "The queue never filled.");
        // Every queued batch is taken at once: well over the eight records one read frames.
        Assert.InRange(run.Next(0).Length, 17, 65535);
        // The completed wait advances the injected clock, then another full queue starts the next wait. No wall-clock
        // threshold is needed to prove backpressure or to abandon a reader blocked on the queue.
        Assert.True(System.Threading.SpinWait.SpinUntil(() => clock.Reads >= 4, TimeSpan.FromSeconds(30)), "The queue never filled again.");
        Assert.True(run.Backpressure >= TimeSpan.FromSeconds(1), $"backpressure {run.Backpressure}");
        run.Abandon();
        Assert.True(run.IsComplete);
        Assert.True(run.Counter.Sequence < 65536);
        // The read blocked on the full queue ends with the abandon: the queue completes once what it held is taken.
        var watch = Stopwatch.StartNew();
        while (run.Next(30000).Length > 0)
        {
        }
        Assert.Empty(run.Next(30000));
        Assert.True(watch.Elapsed.TotalSeconds < 20);
        run.Kill();
    }

    /// <summary>A clock that moves one second each time it is read.</summary>
    private sealed class SteppingClock : TimeProvider
    {
        private long now = 100;

        /// <summary>How many times the clock was read.</summary>
        public long Reads => global::System.Threading.Interlocked.Read(ref now) - 100;

        public override long TimestampFrequency => 1;

        // Inside a TimeProvider, System names its System property: the namespace needs global::.
        public override long GetTimestamp() => global::System.Threading.Interlocked.Increment(ref now);
    }

    [Fact]
    public void TimesTheChildFromItsStartToItsExitWithTheSuppliedClock()
    {
        var clock = new SteppingClock();
        var run = new NativeRun(Child("[Console]::Out.Write('done')"), Strict, '\n', '\n', 64, null, new RecordCounter(), timeProvider: clock);
        using (run)
        {
            Assert.Null(run.ProcessElapsed);
            Assert.True(run.Start());
            run.Read(null, null, null, null);
            Assert.Equal("done", Texts(Drain(run), "stdout"));
            // The exit is timed once WaitForExit returns, by the event or by the wait itself.
            run.WaitForExit();
            // The clock was read at the start and at the exit only, once: nothing waited for room in the queue, and an
            // exit already timed is not timed again.
            Assert.Equal(TimeSpan.FromSeconds(1), run.ProcessElapsed);
            run.WaitForExit();
            Assert.Equal(2, clock.Reads);
            Assert.Equal(TimeSpan.Zero, run.Backpressure);
        }
        using var system = Start(Child("exit"));
        Drain(system);
        system.Process.WaitForExit();
        Assert.True(system.ProcessElapsed > TimeSpan.Zero);
    }

    [Fact]
    public void TimesTheExitWhenItsEventComesLate()
    {
        var clock = new SteppingClock();
        using var run = new NativeRun(Child("exit"), Strict, '\n', '\n', 64, null, new RecordCounter(), timeProvider: clock);
        run.IgnoreExitedEvent();
        Assert.True(run.Start());
        run.Read(null, null, null, null);
        Drain(run);
        // The child exited, but no event timed it: the wait does.
        Assert.Null(run.ProcessElapsed);
        run.WaitForExit();
        Assert.Equal(TimeSpan.FromSeconds(1), run.ProcessElapsed);
        Assert.Equal(2, clock.Reads);
    }

    [Fact]
    public void TimesAnExitNobodyWaitedFor()
    {
        // Without any wait, the exit is still timed: the process raises its Exited event on its own.
        using var unwaited = Start(Child("exit"));
        Drain(unwaited);
        var watch = Stopwatch.StartNew();
        while (unwaited.ProcessElapsed is null && watch.Elapsed < TimeSpan.FromSeconds(20))
        {
            System.Threading.Thread.Sleep(10);
        }

        Assert.NotNull(unwaited.ProcessElapsed);
    }

    [Fact]
    public void RefusesBadArgumentsAndASecondRead()
    {
        ProcessStartInfo info = Child("exit");
        var counter = new RecordCounter();
        Assert.Throws<ArgumentNullException>(() => new NativeRun(null!, Strict, '\n', '\n', 1, null, counter));
        Assert.Throws<ArgumentNullException>(() => new NativeRun(info, null!, '\n', '\n', 1, null, counter));
        Assert.Throws<ArgumentNullException>(() => new NativeRun(info, Strict, '\n', '\n', 1, null, null!));
        Assert.Throws<ArgumentOutOfRangeException>(() => new NativeRun(info, Strict, '\n', '\n', 0, null, counter));
        Assert.Throws<ArgumentOutOfRangeException>(() => new NativeRun(info, Strict, '\n', '\n', 1, null, counter, 0));
        using var idle = new NativeRun(info, Strict, '\n', '\n', 1, null, counter);
        idle.Kill();
        using NativeRun run = Start(info);
        Assert.Equal("The streams are already being read.", Assert.Throws<InvalidOperationException>(() => run.Read(null, null, null, null)).Message);
        Drain(run);
    }
}
