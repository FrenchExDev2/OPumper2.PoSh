using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace FrenchExDev.OPumper2.Engine;

/// <summary>A native process whose two output streams are read on a background task: decoded strictly, captured and
/// framed into records that the caller takes in order with <see cref="Next"/>, on its own thread. Nothing but this
/// class runs on the background tasks, so callbacks stay on the caller's thread. A bounded queue holds the records not
/// taken yet: a slow caller slows the child down instead of buffering its whole output.</summary>
public sealed class NativeRun : IDisposable
{
    private const int QueuedBatches = 64;
    private readonly Process process;
    private readonly Encoding encoding;
    private readonly char stdoutDelimiter;
    private readonly char stderrDelimiter;
    private readonly int maxRecordCharacters;
    private readonly string? inputText;
    private readonly int bufferSize;
    private readonly Channel<List<Record>> records = Channel.CreateBounded<List<Record>>(QueuedBatches);
    private readonly CancellationTokenSource abandon = new();
    private readonly TimeProvider time;
    private CaptureSpool? stdout;
    private CaptureSpool? stderr;
    private bool started;
    private bool disposed;
    private long startTimestamp;
    private long exitTimestamp;
    private long backpressure;

    /// <param name="startInfo">The child, with its environment, arguments and redirections: the caller decides them all.
    /// Its standard input is written with <paramref name="inputText"/>, then closed, when it is redirected.</param>
    /// <param name="timeProvider">The clock of the durations; the system clock unless a test supplies one.</param>
    public NativeRun(ProcessStartInfo startInfo, Encoding encoding, char stdoutDelimiter, char stderrDelimiter, int maxRecordCharacters, string? inputText, RecordCounter counter, int bufferSize = 8192, TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(encoding);
        ArgumentNullException.ThrowIfNull(counter);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxRecordCharacters, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(bufferSize, 1);
        time = timeProvider ?? TimeProvider.System;
        process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        // The exit is timed when it happens, not when a caller next looks.
        process.Exited += OnExited;
        this.encoding = encoding;
        this.stdoutDelimiter = stdoutDelimiter;
        this.stderrDelimiter = stderrDelimiter;
        this.maxRecordCharacters = maxRecordCharacters;
        this.inputText = inputText;
        this.bufferSize = bufferSize;
        Counter = counter;
    }

    public Process Process => process;

    public RecordCounter Counter { get; }

    /// <summary>The capture of standard output so far; final once the run is complete.</summary>
    public NativeCapture? Stdout => stdout?.Snapshot();

    /// <summary>The capture of standard error so far; final once the run is complete.</summary>
    public NativeCapture? Stderr => stderr?.Snapshot();

    /// <summary>True once the streams were abandoned: reads still pending are left to whoever holds the streams open.</summary>
    public bool Abandoned => abandon.IsCancellationRequested;

    /// <summary>True once every record was taken and the child exited, or once the streams were abandoned. A reading
    /// failure keeps it false until <see cref="Next"/> has thrown it.</summary>
    public bool IsComplete => Abandoned || (records.Reader.Completion.IsCompletedSuccessfully && process.HasExited);

    /// <summary>From the start to the exit of the child; null until its Exited event ran or
    /// <see cref="WaitForExit"/> returned.</summary>
    public TimeSpan? ProcessElapsed
    {
        get
        {
            long exit = Interlocked.Read(ref exitTimestamp);
            return exit == 0 ? null : time.GetElapsedTime(startTimestamp, exit);
        }
    }

    /// <summary>How long the readers waited for room in the full queue: the time a slow caller held the child back.</summary>
    public TimeSpan Backpressure => time.GetElapsedTime(0, Interlocked.Read(ref backpressure));

    public bool Start()
    {
        startTimestamp = time.GetTimestamp();
        started = process.Start();
        return started;
    }

    /// <summary>Starts reading both streams into their spools (null when a spool could not be opened), and writing the
    /// input. A failed input write fails the run.</summary>
    public void Read(Stream? stdoutSpool, string? stdoutPath, Stream? stderrSpool, string? stderrPath)
    {
        if (stdout is not null)
        {
            throw new InvalidOperationException("The streams are already being read.");
        }
        stdout = new CaptureSpool("stdout", stdoutSpool, stdoutPath);
        stderr = new CaptureSpool("stderr", stderrSpool, stderrPath);
        Reader[] readers =
        [
            new Reader(stdout, process.StandardOutput.BaseStream, encoding, stdoutDelimiter, maxRecordCharacters, bufferSize, Counter),
            new Reader(stderr, process.StandardError.BaseStream, encoding, stderrDelimiter, maxRecordCharacters, bufferSize, Counter),
        ];
        if (process.StartInfo.RedirectStandardInput)
        {
            _ = Task.Run(WriteInputAsync).ContinueWith(write => records.Writer.TryComplete(write.Exception!.GetBaseException()), CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
        }
        _ = Task.Run(() => PumpAsync(readers));
    }

    /// <summary>The records framed since the last call, waiting at most <paramref name="waitMilliseconds"/> when there are
    /// none yet. Once the streams ended, the wait is for the child to exit. A reading failure is thrown after every record
    /// framed before it was taken.</summary>
    public Record[] Next(int waitMilliseconds)
    {
        List<Record>? taken = Take();
        if (taken is not null)
        {
            return taken.ToArray();
        }
        Task completion = records.Reader.Completion;
        if (completion.IsCompleted)
        {
            completion.GetAwaiter().GetResult();
            if (!Abandoned)
            {
                process.WaitForExit(waitMilliseconds);
            }
            return [];
        }
        try
        {
            records.Reader.WaitToReadAsync().AsTask().Wait(waitMilliseconds);
        }
        catch (AggregateException)
        {
            // The failure is thrown by the next call, which finds the queue completed.
        }
        return Take()?.ToArray() ?? [];
    }

    /// <summary>Waits for the child to exit and makes sure its exit is timed. Process.WaitForExit returns at once when
    /// another thread already runs the Exited handler, possibly before the handler recorded the exit: the exit is then
    /// timed here, a moment late, and the handler, finding it timed, leaves it.</summary>
    public void WaitForExit()
    {
        process.WaitForExit();
        RecordExit();
    }

    /// <summary>Stops timing the exit by its event, as when the event comes too late: tests only.</summary>
    internal void IgnoreExitedEvent() => process.Exited -= OnExited;

    private void OnExited(object? sender, EventArgs e) => RecordExit();

    // The first recorded exit wins; the clock is read only while none is.
    private void RecordExit()
    {
        if (Interlocked.Read(ref exitTimestamp) == 0)
        {
            Interlocked.CompareExchange(ref exitTimestamp, time.GetTimestamp(), 0);
        }
    }

    /// <summary>Kills the child and every process it started, if it still runs.</summary>
    public void Kill()
    {
        if (started && !process.HasExited)
        {
            process.Kill(entireProcessTree: true);
        }
    }

    /// <summary>Stops waiting for the streams: an orphaned grandchild may hold them open forever, and a timeout must return.</summary>
    public void Abandon() => abandon.Cancel();

    /// <summary>Abandons the streams still read, closes the spools and releases the process.</summary>
    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        abandon.Cancel();
        stdout?.Close();
        stderr?.Close();
        process.Dispose();
        abandon.Dispose();
    }

    private List<Record>? Take()
    {
        List<Record>? taken = null;
        while (records.Reader.TryRead(out List<Record>? batch))
        {
            if (taken is null)
            {
                taken = batch;
            }
            else
            {
                taken.AddRange(batch);
            }
        }
        return taken;
    }

    private async Task WriteInputAsync()
    {
        // The child reads its input to the end: the writer closes once the text is written.
        StreamWriter writer = process.StandardInput;
        await writer.WriteAsync(inputText);
        writer.Close();
    }

    private async Task PumpAsync(Reader[] readers)
    {
        try
        {
            Task abandoned = Task.Delay(Timeout.Infinite, abandon.Token);
            foreach (Reader reader in readers)
            {
                reader.BeginRead(abandon.Token);
            }
            while (Array.Exists(readers, reader => !reader.Capture.Ended))
            {
                // Stryker disable once Initializer : pending reads end with the abandon token; waiting for it too is the safety net for a read that ignores it.
                var waiting = new List<Task> { abandoned };
                foreach (Reader reader in readers)
                {
                    if (!reader.Capture.Ended)
                    {
                        waiting.Add(reader.Pending!);
                    }
                }
                // Stryker disable once Block,Statement : a cancelled read ends the loop by itself; leaving here is the safety net for a read that ignores the token.
                if (await Task.WhenAny(waiting) == abandoned)
                {
                    break;
                }
                foreach (Reader reader in readers)
                {
                    if (reader.Capture.Ended || !reader.Pending!.IsCompleted)
                    {
                        continue;
                    }
                    var batch = new List<Record>();
                    reader.Complete(batch, abandon.Token);
                    // A full queue makes the reader wait, and the child behind it: that wait is the backpressure.
                    if (batch.Count > 0 && !records.Writer.TryWrite(batch))
                    {
                        long blocked = time.GetTimestamp();
                        await records.Writer.WriteAsync(batch, abandon.Token);
                        Interlocked.Add(ref backpressure, time.GetTimestamp() - blocked);
                    }
                }
            }
            records.Writer.TryComplete();
        }
        catch (OperationCanceledException) when (abandon.IsCancellationRequested)
        {
            records.Writer.TryComplete();
        }
#pragma warning disable CA1031 // Every reading failure is handed to the caller through the queue.
        catch (Exception exception)
#pragma warning restore CA1031
        {
            records.Writer.TryComplete(exception);
        }
    }

    private sealed class Reader
    {
        private readonly Stream native;
        private readonly byte[] buffer;
        private readonly char[] characters;
        private readonly Decoder decoder;
        private readonly Framer framer;

        public Reader(CaptureSpool capture, Stream native, Encoding encoding, char delimiter, int maxRecordCharacters, int bufferSize, RecordCounter counter)
        {
            Capture = capture;
            this.native = native;
            buffer = new byte[bufferSize];
            characters = new char[encoding.GetMaxCharCount(bufferSize)];
            decoder = encoding.GetDecoder();
            framer = new Framer(capture.Name, delimiter, maxRecordCharacters, counter);
        }

        public CaptureSpool Capture { get; }

        public Task<int>? Pending { get; private set; }

        public void BeginRead(CancellationToken token) => Pending = native.ReadAsync(buffer.AsMemory(), token).AsTask();

        public void Complete(List<Record> batch, CancellationToken token)
        {
            int count = Pending!.GetAwaiter().GetResult();
            if (count == 0)
            {
                Capture.Ended = true;
                // Strict decoding already emitted every complete character; flushing validates an incomplete trailing codepoint.
                decoder.GetCharCount([], 0, 0, flush: true);
                framer.End(batch);
            }
            else
            {
                Capture.Write(buffer, count);
                int length = decoder.GetChars(buffer, 0, count, characters, 0, flush: false);
                framer.Push(characters.AsSpan(0, length), batch);
                BeginRead(token);
            }
        }
    }
}
