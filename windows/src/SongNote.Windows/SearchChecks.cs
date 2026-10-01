using System.Globalization;
using System.Windows.Documents;

namespace SongNote.Windows;

static class SearchChecks
{
    public static int Run()
    {
        var original = CultureInfo.CurrentCulture;
        int cases = 0;
        try
        {
            foreach (var culture in new[] { "zh-Hans-HK", "en-US" })
            {
                CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
                foreach (var sample in new[]
                {
                    (Text: "é", Query: "e\u0301", Highlight: "é"),
                    (Text: "e\u0301", Query: "é", Highlight: "e\u0301"),
                    (Text: "abc", Query: "abc\u00ad", Highlight: "abc"),
                    (Text: "é é", Query: "e\u0301", Highlight: "éé"),
                    (Text: "abc", Query: "\u00ad", Highlight: ""),
                    (Text: "中文 📝", Query: "📝", Highlight: "📝")
                })
                {
                    var block = new TextBlock(); NoteCard.Mark(block, sample.Text, sample.Query);
                    var runs = block.Inlines.OfType<Run>().ToArray();
                    if (string.Concat(runs.Select(r => r.Text)) != sample.Text ||
                        string.Concat(runs.Where(r => r.Background != null).Select(r => r.Text)) != sample.Highlight)
                        throw new InvalidOperationException("Unicode highlighting changed text or used the wrong matched span");
                    cases++;
                }
                // Exercise the actual search/filter/notification path that used
                // to throw from TextChanged, using only an in-memory fixture.
                var note = Note.Blank() with { Text = "é\n虚构搜索测试正文" };
                var state = new LocalState(); state.Notes[note.Id] = note;
                using var controller = new AppController(new LocalStore(new MemoryStateFile { Data = state }), null, true);
                controller.Main.Search.Text = "e\u0301"; controller.Refresh(true);
                if (controller.Model.Items.Count != 1 || controller.Model.Items[0].Id != note.Id)
                    throw new InvalidOperationException("Equivalent Unicode query stopped finding the note");
                var root = (FrameworkElement)controller.Main.Content;
                root.Measure(new Size(460, 710)); root.Arrange(new Rect(0, 0, 460, 710)); root.UpdateLayout();
                controller.Main.Search.Text = ""; controller.Refresh(true); cases++;
            }
        }
        finally { CultureInfo.CurrentCulture = original; }
        return cases;
    }
}
