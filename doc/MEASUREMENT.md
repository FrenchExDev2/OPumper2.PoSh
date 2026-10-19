# Measurement

Source bytes are the complete stdout plus stderr byte streams. Tokens are counted separately per stream by a named, versioned exact local tokenizer, then summed. The source is the command actually executed, not an invented ordinary-command baseline.

Temporary capture files allow analysis after EOF without retaining the capture in the native read buffers. Tokenizer allocation is separate from the bounded native buffers: the packaged tokenizer materializes text while counting. No bounded-memory guarantee is made for that library. A counting error produces unknown tokens, never an estimate. So does a lossy capture: when invalid bytes were replaced while decoding (`Capture.Lossy`), the text is no longer the command's output, and its source tokens stay unknown (`Measurement.Status = CounterUnavailable`).

`AsObject` records the execution, but has no delivered-text measurement until the script delivers it with `Out-OPumper2`, which measures and recalls it like a `pump` delivery. JSON/YAML measurements cover the redacted, bounded final UTF-8 text. Tasks link their source invocation IDs to one delivery; inner calls and nested serializations are not charged as deliveries. Source decoding preserves leading byte-order marks. Native and composed-task elapsed durations are actual stopwatch measurements; an operation without execution has an unknown duration.

## History

SQLite stores counts, outcomes, executable labels, route and provider identifiers, formats, truncation reasons, sessions, salted command fingerprints, project hashes, durations and invocation/delivery links; never captures, command arguments or environment values. The temporary captures are first decoded onto the local completion's `Capture`; they are then removed on all exit paths. Storage errors appear in `Measurement` without changing the domain outcome.

The database is `OPUMPER2_DB_PATH` when set, otherwise `databasePath` from the configuration, by default `~/.opumper2/db.sqlite`. Its schema is an ordered list of migrations, applied in one immediate transaction on first use: an earlier history is migrated in place and keeps its rows, with unknown values for what it did not record; a failing migration rolls back; a newer schema is rejected without being downgraded. The schema is checked once per database and process, and again for a file that did not exist yet. Within a pump or task call, writes share one connection per database path, closed when the outermost call ends. A failed statement drops only its own store, with any transaction it left open; other databases in nested calls remain usable. Transactions never span the native process lifetime.

`Use-OPumper2Environment @{ OPUMPER2_DB_PATH = ...; OPUMPER2_CONFIG_PATH = ... } [{ ... }]` gives the engine, in the current runspace, an environment of its own instead of the process's: for a script block only, or until the next call (`-Reset` returns to the process environment). Tests and concurrent hosts isolate their histories so, without reaching into the module.

Each delivery records:

- its **origin**: route and provider of a routed call, and a fingerprint of the command line, working directory included, keyed by the database's random salt;
- its **format** (`yaml` or `json`), **outcome**, **truncation reasons** and **session** (the value of `OPUMPER2_SESSION`, or of the variable named by `sessionVariable`);
- its **composition**: tokens of the delivered `Data`, records and excerpt; the envelope is the remainder;
- with `measureAlternateFormat: true`, the bytes and tokens of the same delivery in the other format.

Invocations record their session as well. `retentionDays` (90 by default, 0 keeps everything) removes older deliveries with each new one, in the same transaction, then the invocations no remaining delivery needs. `Clear-OPumper2Measurement -Before <date>` or `-All` does the same on demand, with `-WhatIf` and confirmation.

The delivery is measured after its final text is fixed. The serialized completion therefore contains the measurement state preceding delivery; definitive delivered bytes/tokens and storage status are available on the original local completion object and in SQLite. This avoids estimating self-referential output sizes. History comparisons never mix tokenizer profiles or counter versions.

## Gain report

`Get-OPumper2Gain` compares captured source volume with delivered JSON/YAML volume over retained comparable pairs, like `rtk gain` but with exact token counts. Reporting is not itself measured. The report holds:

- totals: source, output and saved bytes and tokens, `Rate` (bytes) and `TokenRate`, elapsed time;
- `Reruns` and `RerunRate`: deliveries whose command line was already delivered within `recallWindowMinutes` (30 by default) in the same history, a sign that the first delivery missed information;
- `Stored`, `Recalled` and `RecallRate`: deliveries whose output went to the [recall store](RECALL.md), and those the agent read back with `Get-OPumper2Recall` instead of running the command again;
- `Lossy` and `LossyRate`: deliveries that omitted something (`ItemLimit`, `DataLimit`, `ExcerptLimit`...);
- `Layers`: delivered tokens split into envelope, `Data`, records and excerpt;
- `Alternate`: delivered tokens against the same deliveries in the other format, when measured;
- `Local`: invocations never delivered (local objects), whose output stayed out of the context;
- `Cost` with `tokenPrice` (per million tokens) and `currency`, and `Quota`: the current month's saved tokens against a budget, the named tier of `quotaTiers` chosen by `-Tier` or `quotaTier` (for example `quotaTiers: { pro: 5000000, max: 20000000 }`), else `monthlyTokenBudget`; an unknown tier fails the report;
- `Advice`: commands with at least three deliveries that cost more than their native output, are often rerun, whose stored outputs are often read back, often truncated, deliver more excerpt than `Data`, or would be at least 10 % smaller in the other format.

Options:

- `-GroupBy` with `Command`, `Route`, `Provider`, `Format`, `Outcome`, `Session`, `Project`, `Day`, `Week` or `Month`, alone or combined, adds `Groups` with the same measures per key. A command is the route of a routed delivery (`dotnet.build`, `git.status`), otherwise the executable. Periods follow the local calendar; weeks are ISO weeks.
- `-History <n>` lists the last deliveries; `-Top <n>` and `-Worst <n>` the largest savings and losses; `-Graph` the saved tokens of the last thirty days.
- `-Since <date>`, `-Project <directory>` (matched by the hash of its full path) and `-Session <name>` filter the history.
- `-DatabasePath` reads one or several databases instead of the configured one, for example the histories of several machines.
- `-AsText` renders tables and a graph for people, `-AsCsv` the total and groups, `-AsLine` one line for a status line; `-AsObject`, `-AsJson` and `-AsYaml` remain available.

`Watch-OPumper2Gain -Report @{ GroupBy = 'Command' } -IntervalSeconds 5` refreshes the text report until interrupted, or `-Count` times.

Saved bytes/tokens may be negative: below a few hundred tokens of native output, the completion envelope costs more than the output it replaces. Rates use total saved divided by total comparable source, not the mean of individual percentages. Unknown values remain null. These are output-volume measurements, not API invoices.

## Time audit

Each call also measures what it costs in time. The durations are milliseconds read from one injectable clock (`Get-OP2Timestamp`), stored in schemas 6 and 7, and kept on the local object (`Execution.Timing`), never delivered.

- **Invocation** (`invocations`): `setup_ms` (from the entry into pump to the start of the child; for a routed call, from the outer entry, so the route and its contract count: the first native call of the handler takes it), `process_ms` (start to exit, timed by the engine's Exited event, or by its wait for the exit should that event still be running), `callback_ms` (the PowerShell callbacks, not the waits for records), `backpressure_ms` (the readers' waits on a full queue: the time the callbacks held the child back), `complete_ms`, `capture_ms`, `tokens_ms`, and `records`.
- **Delivery** (`deliveries`): `total_ms` (from the entry into pump to the delivery's own write, the token counts and the fingerprint included: that write is the one step it cannot include), `recall_ms` (masking and compressing the recall), `format_ms`, `tokens_ms`, `storage_ms` (the writes of the call's invocations and recall since its entry), and `import_ms`, the module import, charged once to the first delivery a session stores.
- Rows stored before schema 6 keep nulls; `elapsed` is unchanged, so the gain report reads them as before.

`Get-OPumper2Audit [-Since] [-GroupBy Route|Command|Provider] [-AsMarkdown|-AsObject|-AsJson|-AsYaml]` sets the time against the tokens:

- A call's **overhead** is `total_ms - process_ms + backpressure_ms`: what pump added on top of the child, the waits it imposed on the child included. A delivery linked to no invocation is all overhead. If any linked invocation lacks `process_ms`, the overhead is unknown, even when other steps have durations. `UnknownDurations` counts these calls; totals, percentiles, phase shares and token-per-overhead rates exclude their unknown overhead.
- **Tokens saved** count only when every count is known and comes from the configured tokenizer (profile and version, as in the gain report): a lossy capture or another tokenizer leaves the saving unknown (`UnknownTokens`), never a negative guess. Tokens saved per second divide the known savings by the overhead of the same calls. With `tokenPrice`, `SavedValue` gives their value in `currency`.
- Per group: runs, runs without known tokens, tokens saved, overhead (total, p50, p95), callback time per thousand lines, backpressure, tokens saved per second of overhead.
- **Overhead by phase** gives each phase's share of the known overhead: setup, backpressure, complete, capture, tokens, recall, format, storage, and Other for work before the delivery write that no phase measured (for example dispatch around the callbacks). The delivery write itself is outside `total_ms` and outside Other. Callbacks run alongside the child: they are part of the overhead only through the backpressure they cause, and are reported per thousand lines. The module import precedes the entry into pump: it is reported apart (`ImportMs`).
- **Local calls** (`-AsObject`, no delivery) are reported apart per command: their overhead is the sum of their measured phases (setup, backpressure, complete, capture, tokens).
- `-AsMarkdown` renders a page.

## Switches

`tracking: false` or `OPUMPER2_TRACKING=0` records nothing: no invocation, delivery or recall. `envelope: compact` delivers only `Kind`, `Outcome`, `Data`, the exit code and issues, `Error`, `Excerpt`, `Truncation` and `Recall`; it is the first remedy when the report shows negative savings on small outputs. Contributor reports delivered with `Format-OPumper2Report` (discovery, sessions) follow the same envelope and are not measured.
