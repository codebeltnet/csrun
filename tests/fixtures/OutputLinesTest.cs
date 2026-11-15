using Codebelt.Extensions.Xunit;
using Xunit;

namespace Example.Tests;

public class OutputLinesTest : Test
{
    public OutputLinesTest(ITestOutputHelper output) : base(output) { }

    [Fact]
    public void ShouldWriteValuesOnSeparateLines()
    {
        TestOutput.WriteLines("started", 2, "finished");
        Assert.True(HasTestOutput);
    }
}
