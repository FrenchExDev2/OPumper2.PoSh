using System;
using System.Threading.Tasks;
using Microsoft.ML.Tokenizers;

namespace FrenchExDev.OPumper2.Engine;

/// <summary>Creates a tiktoken tokenizer on a background task. Loading a vocabulary takes about a quarter of a second,
/// which a call spends while its child runs instead of after it. The caller names the encoding: nothing here reads the
/// configuration. An unknown encoding faults the task, and whoever takes its result gets that failure.</summary>
public static class TokenizerWarmup
{
    public static Task<Tokenizer> Start(string encoding)
    {
        ArgumentNullException.ThrowIfNull(encoding);
        return Task.Run<Tokenizer>(() => TiktokenTokenizer.CreateForEncoding(encoding));
    }
}
