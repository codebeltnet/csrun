using System;
using System.Globalization;
using Cuemon;

namespace DateExamples;

internal static class Program
{
    private static void Main()
    {
        var span = new DateSpan(
            new DateTime(2018, 1, 1),
            new DateTime(2018, 10, 1));

        Console.WriteLine($"{span.Years} years");
        Console.WriteLine($"{span.Months} months");
        Console.WriteLine($"{span.GetWeeks()} weeks");
        Console.WriteLine($"{span.TotalDays} days");
        Console.WriteLine($"{span.TotalHours} hours");
        Console.WriteLine(span.TotalMinutes.ToString("N0", CultureInfo.InvariantCulture) + " minutes");
        Console.WriteLine(span.TotalSeconds.ToString("N0", CultureInfo.InvariantCulture) + " seconds");
    }
}
