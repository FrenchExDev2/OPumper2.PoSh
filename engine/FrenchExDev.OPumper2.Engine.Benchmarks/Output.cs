namespace FrenchExDev.OPumper2.Engine.Benchmarks;

using System.Globalization;
using System.Text;

/// <summary>The native output the benchmarks read: MSBuild-like lines, 1 % errors and 1 % warnings, as
/// test/Measure-OP2Performance.ps1 writes them.</summary>
internal static class Output
{
    /// <summary>The text of a number of lines, each ending with a line feed.</summary>
    /// <param name="lines">How many lines.</param>
    /// <returns>The text.</returns>
    public static string Lines(int lines)
    {
        var builder = new StringBuilder(lines * 96);
        for (int index = 1; index <= lines; index++)
        {
            string project = string.Create(CultureInfo.InvariantCulture, $"P{index % 7}");
            if (index % 100 == 0)
            {
                builder.Append(CultureInfo.InvariantCulture, $"C:\\src\\{project}\\F{index}.cs(10,5): error CS{index % 40:0000}: The name 'Thing{index}' does not exist in the current context [C:\\src\\{project}\\{project}.csproj::TargetFramework=net10.0]\n");
            }
            else if (index % 50 == 0)
            {
                builder.Append(CultureInfo.InvariantCulture, $"C:\\src\\{project}\\F{index}.cs(12,9): warning CA{1000 + (index % 40):0000}: Consider doing something about member {index} [C:\\src\\{project}\\{project}.csproj::TargetFramework=net10.0]\n");
            }
            else
            {
                builder.Append(CultureInfo.InvariantCulture, $"  Determining projects to restore for item {index}... {project} -> C:\\src\\bin\\{project}.dll\n");
            }
        }

        return builder.ToString();
    }
}
