namespace FrenchExDev.OPumper2.Engine.Benchmarks;

using BenchmarkDotNet.Running;

/// <summary>Runs the benchmarks the arguments select (--filter *), or asks which.</summary>
public static class Program
{
    /// <summary>The entry point.</summary>
    /// <param name="args">BenchmarkDotNet arguments.</param>
    public static void Main(string[] args) => BenchmarkSwitcher.FromAssembly(typeof(Program).Assembly).Run(args);
}
