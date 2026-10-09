using System.IO.Pipes;
using System.Windows.Media.Imaging;

namespace SongNote.Windows;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        System.Windows.Forms.Application.SetHighDpiMode(System.Windows.Forms.HighDpiMode.PerMonitorV2);
        bool check = args.Contains("--check-ui"), demo = args.Contains("--offline-demo");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        Theme.Install(app); Motion.Initialize();
        if (check)
        {
            Motion.Suppress = true;
            try { Diagnostics.Run(args); Motion.Dispose(); return 0; }
            catch (Exception e)
            {
                var output = args.SkipWhile(a => a != "--output").Skip(1).FirstOrDefault() ?? AppContext.BaseDirectory;
                Directory.CreateDirectory(output); File.WriteAllText(Path.Combine(output, "error.txt"), e.ToString()); return 1;
            }
        }
        var data = demo ? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "demo-data")) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SongNote");
        string userId = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        string instance = "SongNote-" + userId + (demo ? "-demo" : "");
        using var mutex = new Mutex(true, "Global\\" + instance, out bool first);
        if (!first)
        {
            try { using var pipe = new NamedPipeClientStream(".", instance, PipeDirection.Out); pipe.Connect(1500); using var writer = new StreamWriter(pipe); writer.WriteLine("show"); }
            catch (IOException) { }
            catch (TimeoutException) { }
            return 0;
        }
        AppController? controller = null;
        using var lifetime = new CancellationTokenSource();
        try
        {
            var store = new LocalStore(new AtomicStateFile(data)); Configuration? config = null;
            if (!demo)
            {
                var saved = Path.Combine(data, "client-config.json"); var bundled = Path.Combine(AppContext.BaseDirectory, "client-config.json");
                if (!File.Exists(saved) && File.Exists(bundled)) File.Copy(bundled, saved);
                if (File.Exists(saved)) { config = ProtocolJson.Decode<Configuration>(File.ReadAllText(saved)); config.Validate(); }
            }
            controller = new(store, config, filePicker: demo ? new AttachmentPicker(data) : null); app.MainWindow = controller.Main;
            _ = Listen(instance, controller, lifetime.Token);
            app.Startup += (_, _) => controller.Start();
            app.SessionEnding += (_, e) =>
            {
                if (!controller.PrepareExit()) e.Cancel = true;
            };
            app.Exit += (_, _) => { lifetime.Cancel(); controller.Dispose(); Motion.Dispose(); };
            app.Run(); return 0;
        }
        catch (Exception e)
        {
            controller?.Dispose(); Motion.Dispose();
            NoteDialog.Alert(null, "无法启动 SongNote", "原数据文件已保留。\n" + e.Message); return 1;
        }
    }
    static async Task Listen(string name, AppController controller, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                using var pipe = new NamedPipeServerStream(name, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(token); using var reader = new StreamReader(pipe); await reader.ReadLineAsync(token);
                _ = controller.Main.Dispatcher.BeginInvoke(new Action(() => controller.ShowList()));
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (IOException) { }
    }
}

public sealed class MemoryStateFile : IStateFile
{
    public LocalState Data { get; set; } = new();
    public bool FailWrite { get; set; }
    public LocalState? Read() => Data.Copy();
    public void Write(LocalState state) { if (FailWrite) throw new IOException("Injected UI save failure"); Data = state.Copy(); }
}
public static class Diagnostics
{
    static void Require(bool condition, string error) { if (!condition) throw new InvalidOperationException(error); }
    public static void Run(string[] args)
    {
        var output = args.SkipWhile(a => a != "--output").Skip(1).FirstOrDefault() ?? Path.Combine(AppContext.BaseDirectory, "ui-check");
        output = Path.GetFullPath(output); Directory.CreateDirectory(output);
        var fixture = new LocalState();
        string[] texts = ["周五前交周报\n整理客户反馈，补上三季度数据", "服务器备份检查\n每小时一份，保留 48 份", "读书笔记\n第三章 · 习惯的回路", "妈妈生日\n10 月 18 日，订蛋糕", "新项目点子\n先让写字的地方更安静", "买菜清单\n鸡蛋、牛奶、西红柿、面条", "同步冲突测试\n保留两端的文字"];
        for (int i = 0; i < texts.Length; i++) { var note = Note.Blank() with { Text = texts[i], Color = Theme.Colors[i % 6], Pinned = i < 2, UpdatedAt = DateTimeOffset.Now.AddMinutes(-i * 30).ToString("O") }; fixture.Notes[note.Id] = note; }
        var store = new LocalStore(new MemoryStateFile { Data = fixture }); using var controller = new AppController(store, null, true);
        var main = controller.Main; int cases = 0;
        using (var resource = Application.GetResourceStream(new Uri("pack://application:,,,/SongNote.ico"))!.Stream)
        using (var icon = new System.Drawing.Icon(resource)) { Require(icon.Width > 0, "Tray/application icon resource missing"); cases++; }
        foreach (var width in new[] { 360d, 460, 650, 680, 720 })
        {
            Layout(main, width, 710); var panel = NoteCard.Descendant<ResponsiveNotesPanel>(main.Notes) ?? throw new InvalidOperationException("List panel not created");
            Require(panel.Children.Count == 7, "Seven fixture cards were not laid out");
            Require(panel.Columns == (panel.ActualWidth >= 620 ? 2 : 1), "Wrong responsive column count");
            foreach (FrameworkElement child in panel.Children)
            {
                var p = child.TranslatePoint(new Point(0, 0), panel);
                Require(child.ActualWidth > 100 && p.X >= -1 && p.X + child.ActualWidth <= panel.ActualWidth + 1, "Card clipped horizontally");
                Require(p.Y + child.ActualHeight <= panel.ActualHeight + 1, "Last row clipped");
            }
            Require(panel.Headers.Count >= 2 && panel.Headers[0].Title == "置顶", "Pinned and dated sections missing");
            foreach (FrameworkElement child in panel.Children)
            {
                var bounds = new Rect(child.TranslatePoint(new Point(0, 0), panel), child.RenderSize);
                Require(panel.Headers.All(h => !h.Bounds.IntersectsWith(bounds)), "Section header overlaps a row");
            }
            if (width == 460) Require(main.Notes.ActualHeight >= 9 * (ResponsiveNotesPanel.RowHeight + ResponsiveNotesPanel.RowGap), "Default list cannot show nine rows");
            Render(main, Path.Combine(output, $"list-{width:0}.png")); cases++;
        }
        var example = fixture.Visible()[0]; controller.Open(example.Id); var window = controller.Editors[example.Id];
        foreach (var width in new[] { 280d, 380, 640 }) { Layout(window, width, 420); Require(window.Editor.ActualHeight > 300, "Editor squeezed by toolbar"); Render(window, Path.Combine(output, $"note-{width:0}.png")); cases++; }
        // Sticky notes: minimise/close only; the list keeps the full caption set.
        Require(!window.CanMaximize && window.CaptionButtonCount == 2 && main.CanMaximize && main.CaptionButtonCount == 3, "Caption buttons: note must not offer maximise"); cases++;
        // A pinned note shows a tinted pin, never the solid ink block that read as a stuck button.
        Require(example.Pinned && window.PinButton.Background is SolidColorBrush pinFill && pinFill.Color != Theme.Ink && pinFill.Color.A > 0, "Pinned state should be a colour tint"); cases++;
        var more = controller.NoteMenu(example.Id, window); RenderElement(more, Path.Combine(output, "menu-more.png"), 280);
        var headers = more.Items.OfType<MenuItem>().Select(i => i.Header as string).ToArray();
        Require(headers.Contains("添加附件…") && headers.Contains("删除便签…") && headers.Contains("总在最前（仅本机窗口）") && !headers.Any(h => h?.Contains("最大化") == true), "More menu entries changed"); cases++;
        Require(window.AttachmentPanel.Visibility == Visibility.Collapsed, "Empty attachment area occupies note space"); cases++;
        for (int i = 0; i < 8; i++) store.AddAttachment(example.Id, new(Guid.NewGuid().ToString(), "很长的虚构附件名称用于检查窄窗截断-" + i + ".pdf", 1024, new string('a', 64)));
        window.Refresh(); Layout(window, 380, 420);
        foreach (var size in new[] { new Size(280, 240), new Size(380, 420), new Size(640, 640) })
        {
            Layout(window, size.Width, size.Height); var strip = window.AttachmentPanel;
            Require(strip.Visibility == Visibility.Visible && strip.ActualHeight <= AttachmentStrip.ChipHeight + 1, "Attachment chips missing or taller than one line");
            Require(window.Editor.ActualHeight > 40, "Attachment chips squeeze the editor");
            Require(strip.Shown > 0 && strip.Shown < 8 && strip.Overflow.Visibility == Visibility.Visible && Equals(strip.Overflow.Content, "+" + (8 - strip.Shown)), "Overflowing chips are not collapsed into +N");
            var p = strip.TranslatePoint(new Point(), (FrameworkElement)window.Content);
            Require(p.X >= 0 && p.X + strip.ActualWidth <= size.Width, "Attachment chips overflow horizontally");
            var shown = strip.Children.OfType<FrameworkElement>().Where(c => c.Visibility == Visibility.Visible).Select(c => new Rect(c.TranslatePoint(new Point(), strip), c.RenderSize)).ToArray();
            Require(shown.All(r => r.Left >= 0 && r.Right <= strip.ActualWidth + 1) && shown.All(a => shown.Count(b => a.IntersectsWith(b) && a != b) == 0), "Attachment chips clipped or overlapping");
            Render(window, Path.Combine(output, $"note-attachments-{size.Width:0}.png")); cases++;
        }
        // Return the main fixture to its original content for the existing close/delete checks.
        foreach (var a in store.Snapshot().Notes[example.Id].Attachments ?? []) store.RemoveAttachment(example.Id, a.Id);
        var attachmentSent = store.Freeze().Changes;
        store.Apply(new(1, 1, store.Snapshot().Notes.Values.Select(n => n.Id == example.Id ? n with { Revision = 1 } : n).ToArray(), [new(attachmentSent[0].OpId, example.Id, 1, "applied")]), attachmentSent);
        window.Refresh();
        var conflict = example with { ConflictOf = "missing-original" }; var state = store.Snapshot(); state.Notes[example.Id] = conflict;
        var file = new MemoryStateFile { Data = state }; var conflictStore = new LocalStore(file); using var second = new AppController(conflictStore, null, true); second.Open(example.Id);
        var conflictWindow = second.Editors[example.Id]; Layout(conflictWindow, 280, 240); Require(conflictWindow.Notice.Visibility == Visibility.Visible && conflictWindow.Editor.ActualHeight >= 120, "Conflict notice squeezed editor"); Render(conflictWindow, Path.Combine(output, "note-conflict-min.png")); cases++;
        // Exercise the actual native-window Closing call path with only fixtures.
        window.Opacity = 0; window.ShowActivated = false; window.Show(); Pump();
        Require(window.IsLoaded, "Native fixture window not loaded");
        NativeMonitor.Restore(window, new Placement(-100000, 100000, 380, 420), null); Pump();
        var physical = NativeMonitor.NormalBounds(window) ?? throw new InvalidOperationException("Native window rectangle missing");
        Require(System.Windows.Forms.Screen.AllScreens.Any(s => physical.Left >= s.WorkingArea.Left - 1 && physical.Top >= s.WorkingArea.Top - 1 && physical.Left + physical.Width <= s.WorkingArea.Right + 1 && physical.Top + physical.Height <= s.WorkingArea.Bottom + 1), "Restored window remains offscreen"); cases++;
        var tombstones = store.Snapshot().Notes.Values.Select(n => n.Id == example.Id ? n with { Text = "远端修改后删除", Deleted = true, Revision = 10 } : n).ToArray();
        store.Apply(new(1, 10, tombstones, []), []); window.Refresh(); Pump();
        Require(!store.Snapshot().Pending.ContainsKey(example.Id) && store.Snapshot().Notes[example.Id].Deleted, "Remote close resurrected a tombstone"); cases++;
        main.Notes.SelectedIndex = 0; var selected = main.Notes.ItemContainerGenerator.ContainerFromIndex(0) as ListBoxItem;
        var firstCard = selected == null ? null : NoteCard.Descendant<NoteCard>(selected);
        if (firstCard == null) throw new InvalidOperationException("Selected card not generated");
        Require(firstCard.SelectionHighlighted, "Card selection highlight did not update immediately");
        main.Notes.SelectedIndex = 1;
        var secondItem = main.Notes.ItemContainerGenerator.ContainerFromIndex(1) as ListBoxItem;
        Require(firstCard.SelectionHighlighted == false && secondItem != null && NoteCard.Descendant<NoteCard>(secondItem)?.SelectionHighlighted == true, "Old selection border was not cleared"); cases++;
        Motion.Stop(); Motion.Suppress = false;
        var animated = Theme.Brush("#FFF5C9"); Motion.Color(animated, Theme.Paper("green").Color); Motion.Color(animated, Theme.Paper("blue").Color);
        Require(Motion.ActiveCount <= 1, "Replacing a color animation leaked its clock");
        Motion.Stop(); Require(animated.Color == Theme.Paper("blue").Color && Motion.ActiveCount == 0, "Stopping motion restored a stale target");
        var rotation = new RotateTransform(); Motion.Spin(rotation, true); Motion.Spin(rotation, false); Require(Motion.ActiveCount == 0, "Stopped spinner still retained"); Motion.Suppress = true; cases++;
        var failureFile = new MemoryStateFile { Data = fixture.Copy() }; var failureStore = new LocalStore(failureFile);
        using var third = new AppController(failureStore, null, true); third.Open(example.Id); var failureWindow = third.Editors[example.Id];
        failureWindow.Opacity = 0; failureWindow.ShowActivated = false; failureWindow.Show(); Pump();
        failureFile.FailWrite = true; failureStore.Delete(example.Id); failureWindow.Refresh(); Pump();
        Require(third.Editors.ContainsKey(example.Id) && failureWindow.Editor.IsReadOnly && failureWindow.Footer.Text.Contains("保存失败"), "Failed deletion closed/reopened recursively or hid the save failure");
        Layout(failureWindow, 280, 240); Render(failureWindow, Path.Combine(output, "note-save-failure-min.png")); cases++;
        failureFile.FailWrite = false; Require(failureStore.RetrySave(), "UI fixture could not recover save"); failureWindow.Refresh(); Pump();
        var vacantStore = new LocalStore(new MemoryStateFile()); using (var vacant = new AppController(vacantStore, null, true))
        {
            Layout(vacant.Main, 460, 710); Require(vacant.Main.EmptyStateVisible, "Empty list does not invite a first note");
            Render(vacant.Main, Path.Combine(output, "list-empty.png")); vacant.Main.Close(); cases++;
        }
        foreach (var choice in new[] { "cancel", "action", "escape", "close", "alert" })
        {
            var dialog = new NoteDialog(choice == "alert" ? "附件下载失败" : "删除便签",
                choice == "alert" ? "网络暂时不可用，请稍后重试。\n附件仍保留在便签中。" : "删除这条便签？\n删除会同步到另一台电脑。", choice == "alert" ? null : "删除");
            dialog.ShowActivated = false;
            Exception? failure = null;
            dialog.Loaded += (_, _) => dialog.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
            {
                try
                {
                    Require(!dialog.ActionButton.IsDefault && (string)dialog.DismissButton.Content == (choice == "alert" ? "知道了" : "取消"), "Unsafe dialog default or ambiguous label");
                    if (choice is "cancel" or "alert") Render(dialog, Path.Combine(output, "dialog-" + choice + ".png"));
                    if (choice == "close") dialog.Close();
                    else if (choice == "escape") dialog.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(dialog)!, 0, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
                    else (choice == "action" ? dialog.ActionButton : dialog.DismissButton).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                }
                catch (Exception e) { failure = e; dialog.Close(); }
            }));
            bool accepted = dialog.ShowDialog() == true;
            if (failure != null) throw failure;
            Require(accepted == (choice == "action"), "Dialog close/cancel accepted destructive action"); cases++;
        }
        cases += ScrollBarChecks.Run(output);
        cases += SearchChecks.Run();
        cases += AttachmentPickerChecks.Run();
        File.WriteAllText(Path.Combine(output, "result.txt"), $"UI_CHECK_OK: {cases} native WPF cases; layout, state safety and scrollbar interaction. No production data/network/startup changes.\n");
        main.Close(); window.Close(); second.Main.Close(); conflictWindow.Close();
    }
    static void Layout(Window window, double width, double height)
    {
        window.Width = width; window.Height = height;
        var content = (FrameworkElement)window.Content; content.Measure(new Size(width, height)); content.Arrange(new Rect(0, 0, width, height)); content.UpdateLayout();
    }
    static void Pump()
    {
        var frame = new DispatcherFrame(); Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false)); Dispatcher.PushFrame(frame);
    }
    static void RenderElement(FrameworkElement element, string path, double width)
    {
        element.Measure(new Size(width, double.PositiveInfinity)); element.Arrange(new Rect(element.DesiredSize)); element.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(element.ActualWidth), (int)Math.Ceiling(element.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(element);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(path); png.Save(stream);
    }
    static void Render(Window window, string path)
    {
        var root = (FrameworkElement)window.Content;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth), (int)Math.Ceiling(root.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(root);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(path); png.Save(stream);
    }
}
