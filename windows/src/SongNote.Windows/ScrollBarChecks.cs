using System.Windows.Controls.Primitives;
using System.Windows.Media.Imaging;

namespace SongNote.Windows;

// Isolated native UI checks, using only synthetic text and an in-memory store.
static class ScrollBarChecks
{
    static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    public static int Run(string output)
    {
        var state = new LocalState();
        for (int i = 0; i < 30; i++)
        {
            var note = Note.Blank() with { Text = $"滚动检查便签 {i + 1}\n列表与正文使用相同的轻量滚动条", Color = Theme.Colors[i % 6] };
            state.Notes[note.Id] = note;
        }
        var editorNote = state.Visible()[0] with { Color = "green", Text = string.Join("\n", Enumerable.Range(1, 100).Select(i => $"第 {i} 行：这是滚动条检查的虚构正文。")) };
        state.Notes[editorNote.Id] = editorNote;
        var store = new LocalStore(new MemoryStateFile { Data = state });
        using var controller = new AppController(store, null, true);
        controller.Open(editorNote.Id); var window = controller.Editors[editorNote.Id];
        window.ShowActivated = false; window.Opacity = 0; window.Show(); Pump();
        int cases = 0;
        foreach (var width in new[] { 280d, 380 })
        {
            Layout(window, width, 420);
            var viewer = NoteCard.Descendant<ScrollViewer>(window.Editor) ?? throw new InvalidOperationException("Editor scroll viewer missing");
            CheckBar(viewer); Render(window, Path.Combine(output, $"scroll-note-{width:0}.png")); cases++;
        }
        var editorScroll = NoteCard.Descendant<ScrollViewer>(window.Editor)!;
        CheckInteraction(editorScroll); cases++;
        foreach (var height in new[] { 360d, 710 })
        {
            Layout(controller.Main, 460, height);
            var viewer = NoteCard.Descendant<ScrollViewer>(controller.Main.Notes) ?? throw new InvalidOperationException("List scroll viewer missing");
            CheckBar(viewer); Render(controller.Main, Path.Combine(output, $"scroll-list-{height:0}.png")); cases++;
        }
        CheckInteraction(NoteCard.Descendant<ScrollViewer>(controller.Main.Notes)!); cases++;
        var shortState = store.Snapshot(); shortState.Notes[editorNote.Id] = editorNote with { Text = "短正文不需要滚动条" };
        store.Apply(new(1, 0, shortState.Notes.Values.ToArray(), []), []); window.Refresh(); Pump();
        Layout(window, 380, 420);
        Require(editorScroll.ComputedVerticalScrollBarVisibility != Visibility.Visible, "Short note still displays a scroll bar"); cases++;
        File.WriteAllText(Path.Combine(output, "scrollbar-result.txt"), $"SCROLLBAR_CHECK_OK: {cases} cases; narrow/full editor, short/long list, page/wheel/thumb interaction and automatic hiding.\n");
        window.Close(); controller.Main.Close(); return cases;
    }
    static ScrollBar CheckBar(ScrollViewer viewer)
    {
        viewer.ApplyTemplate(); viewer.UpdateLayout();
        var bar = (ScrollBar?)viewer.Template.FindName("PART_VerticalScrollBar", viewer) ?? throw new InvalidOperationException("Vertical scroll bar missing");
        bar.ApplyTemplate(); var track = (Track?)bar.Template.FindName("PART_Track", bar) ?? throw new InvalidOperationException("Scroll track missing");
        track.Thumb.ApplyTemplate();
        Require(bar.Visibility == Visibility.Visible && Math.Abs(bar.ActualWidth - 12) < .5, "Scroll bar did not use the 12-DIP transparent rail");
        Require(track.Orientation == Orientation.Vertical && track.IsDirectionReversed, "Vertical track direction changed");
        Require(track.DecreaseRepeatButton.Command == ScrollBar.PageUpCommand && track.IncreaseRepeatButton.Command == ScrollBar.PageDownCommand, "Page commands lost");
        var grip = (Border?)track.Thumb.Template.FindName("Grip", track.Thumb) ?? throw new InvalidOperationException("Rounded thumb missing");
        Require(grip.Width == 6 && grip.CornerRadius.TopLeft == 3, "Thumb is not thin and round");
        Require(viewer.ScrollableHeight > 0 && track.Thumb.ActualHeight >= 24, "Long content is not scrollable or thumb too small");
        return bar;
    }
    static void CheckInteraction(ScrollViewer viewer)
    {
        var bar = CheckBar(viewer); viewer.ScrollToTop(); Pump();
        ScrollBar.PageDownCommand.Execute(null, bar); Pump(); Require(viewer.VerticalOffset > 0, "Page click did not move content");
        viewer.ScrollToTop(); Pump();
        viewer.RaiseEvent(new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, -120) { RoutedEvent = Mouse.MouseWheelEvent });
        Pump(); Require(viewer.VerticalOffset > 0, "Wheel scrolling stopped working");
        viewer.ScrollToTop(); Pump();
        var track = (Track)bar.Template.FindName("PART_Track", bar);
        track.Thumb.RaiseEvent(new DragStartedEventArgs(0, 0) { RoutedEvent = Thumb.DragStartedEvent });
        track.Thumb.RaiseEvent(new DragDeltaEventArgs(0, 20) { RoutedEvent = Thumb.DragDeltaEvent });
        track.Thumb.RaiseEvent(new DragCompletedEventArgs(0, 20, false) { RoutedEvent = Thumb.DragCompletedEvent });
        Pump(); Require(viewer.VerticalOffset > 0, "Thumb drag did not move content");
        viewer.ScrollToTop(); Pump();
    }
    static void Layout(Window window, double width, double height)
    {
        window.Width = width; window.Height = height;
        var root = (FrameworkElement)window.Content; root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout(); Pump();
    }
    static void Pump()
    {
        var frame = new DispatcherFrame(); Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false)); Dispatcher.PushFrame(frame);
    }
    static void Render(Window window, string path)
    {
        var root = (FrameworkElement)window.Content;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth), (int)Math.Ceiling(root.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(root);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap)); using var file = File.Create(path); png.Save(file);
    }
}
