using Microsoft.Win32;
using System.Net.Http;
using System.Windows.Shell;
using Forms = System.Windows.Forms;

namespace SongNote.Windows;

public sealed class AppController : IDisposable
{
    public static AppController Current { get; private set; } = null!;
    public LocalStore Store { get; }
    public SyncService Sync { get; }
    public AttachmentPicker FilePicker { get; }
    public MainWindow Main { get; }
    public MainViewModel Model { get; } = new();
    public Dictionary<string, NoteWindow> Editors { get; } = [];
    public bool Quitting { get; private set; }
    public bool Preview { get; }
    readonly Dispatcher dispatcher;
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(30) };
    Forms.NotifyIcon? tray;
    readonly Forms.ContextMenuStrip trayMenu = new();
    readonly System.Drawing.Icon? icon;
    public AppController(LocalStore store, Configuration? config, bool preview = false, AttachmentPicker? filePicker = null, string? attachmentDirectory = null)
    {
        Current = this; Store = store; Preview = preview; dispatcher = Application.Current.Dispatcher;
        FilePicker = filePicker ?? new(); Sync = new(store, config, attachmentDirectory: attachmentDirectory); Main = new(Model);
        Store.Changed += () => dispatcher.BeginInvoke(new Action(() => Refresh()));
        Sync.Changed += () => dispatcher.BeginInvoke(new Action(() => Refresh()));
        Store.Accepted += (mapping, receipts, sent) => dispatcher.Invoke(() =>
        {
            foreach (var pair in mapping)
                if (Editors.Remove(pair.Key, out var editor)) { editor.Remap(pair.Value, receipts, sent); Editors[pair.Value] = editor; }
            foreach (var editor in Editors.Values) editor.Remap(editor.Id, receipts, sent);
            if (Main.Notes.SelectedItem is NoteViewModel selected && mapping.TryGetValue(selected.Id, out var next))
            { Refresh(); Main.Notes.SelectedItem = Model.Items.FirstOrDefault(i => i.Id == next); }
        });
        clock.Tick += (_, _) => Refresh(); if (!preview) clock.Start();
        if (!preview)
        {
            using var stream = Application.GetResourceStream(new Uri("pack://application:,,,/SongNote.ico"))!.Stream;
            icon = new System.Drawing.Icon(stream); tray = new Forms.NotifyIcon { Icon = icon, Text = "SongNote 便签", ContextMenuStrip = trayMenu, Visible = true };
            tray.DoubleClick += (_, _) => dispatcher.BeginInvoke(new Action(() => ShowList()));
            trayMenu.Opening += (_, _) => BuildTray();
            trayMenu.Renderer = new Forms.ToolStripProfessionalRenderer(new TrayColors()) { RoundedEdges = false };
            trayMenu.Font = new System.Drawing.Font("Microsoft YaHei UI", 9f); trayMenu.ShowImageMargin = false; trayMenu.Padding = new Forms.Padding(2, 4, 2, 4);
        }
        Refresh();
    }
    public void Start()
    {
        Restore("list", Main); ShowList();
        foreach (var id in Store.Snapshot().OpenNotes) Open(id); Sync.Start();
    }
    public Note? CurrentNote(string id) => Store.Snapshot().Notes.GetValueOrDefault(id);
    public void Refresh(bool forceOrder = false)
    {
        var state = Store.Snapshot();
        string status = Store.LastSaved ? Sync.Status : "本地保存失败，请勿退出";
        int notices = state.Visible().Count(n => n.ConflictOf != null || state.DeleteConflictIds.Contains(n.Id)); if (notices > 0) status += $" · {notices} 条冲突提醒";
        var selected = (Main.Notes.SelectedItem as NoteViewModel)?.Id;
        Model.Refresh(state, status, !forceOrder && Editors.Values.Any(w => w.Editing));
        if (selected != null) Main.Notes.SelectedItem = Model.Items.FirstOrDefault(i => i.Id == selected && !i.Removing);
        Main.Refresh(state, Sync, Store.LastSaved, Store.SaveError);
        foreach (var window in Editors.Values.ToArray()) window.Refresh();
    }
    public void NewNote() { var note = Store.CreateDraft(); Open(note.Id); }
    public void Open(string id)
    {
        if (Editors.TryGetValue(id, out var existing)) { if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal; existing.Show(); existing.Activate(); return; }
        if (CurrentNote(id) is not { Deleted: false } note) return;
        var window = new NoteWindow(this, note); Editors[id] = window; Restore(id, window);
        if (!Preview) { window.Show(); window.Editor.Focus(); Store.SaveOpenNotes(Editors.Keys); }
    }
    public void NoteClosed(string id)
    {
        Editors.Remove(id); if (!Preview && !Quitting) Store.SaveOpenNotes(Editors.Keys); Refresh(true);
    }
    public void ShowList(bool search = false)
    {
        if (Main.WindowState == WindowState.Minimized) Main.WindowState = WindowState.Normal;
        Main.Show(); Main.Activate(); if (search) Main.Search.Focus(); Refresh(true);
    }
    public async Task SyncNow() { foreach (var editor in Editors.Values.ToArray()) editor.SaveText(); await Sync.Sync(force: true); }
    public void Pin(string id) { Store.TogglePin(id); if (Editors.TryGetValue(id, out var window) && CurrentNote(id) is Note note) window.ChangePinDuringComposition(note.Pinned); Sync.AfterEdit(); }
    public void Color(string id, string color) { Store.SetColor(id, color); if (Editors.TryGetValue(id, out var window)) window.ChangeColorDuringComposition(color); Sync.AfterEdit(); }
    public async Task AddAttachment(string id, NoteWindow? window = null)
    {
        if (Sync.Files == null) return;
        if (window == null) { Open(id); window = Editors.GetValueOrDefault(id); }
        try
        {
            var paths = await FilePicker.Open();
            if (paths == null || !AttachmentTargetAlive(window?.Id ?? id, window)) return;
            if (paths.Length + (CurrentNote(window?.Id ?? id)?.Attachments?.Length ?? 0) > 20)
                throw new InvalidDataException("每条便签最多 20 个附件，请减少选择的文件。");
            foreach (var path in paths)
            {
                var attachment = await Task.Run(() => Sync.Files.Import(path));
                var target = window?.Id ?? id;
                if (!AttachmentTargetAlive(target, window)) return;
                Store.AddAttachment(target, attachment);
                if (Editors.TryGetValue(target, out var editor)) editor.ChangeAttachmentsDuringComposition(CurrentNote(target)?.Attachments);
                if (!Store.LastSaved) throw new IOException("附件信息保存失败，请先重试本地保存。文件已保留。");
            }
            Sync.AfterEdit(); Refresh();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
        { AttachmentError(window, e.Message, "无法添加附件"); }
    }
    bool AttachmentTargetAlive(string id, NoteWindow? window) => !Quitting && !dispatcher.HasShutdownStarted && CurrentNote(id) is { Deleted: false } &&
        (window == null || (Editors.TryGetValue(window.Id, out var current) && ReferenceEquals(current, window)));
    void AttachmentError(NoteWindow? owner, string message, string title)
    {
        if (Quitting || dispatcher.HasShutdownStarted) return;
        MessageBox.Show(owner != null && Editors.Values.Contains(owner) ? owner : Main, message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
    }
    public void RemoveAttachment(string id, Attachment value, NoteWindow window)
    {
        if (MessageBox.Show(window, "从这条便签移除附件？\n" + value.Name + "\n移除会同步到另一台电脑。", "移除附件", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        Store.RemoveAttachment(id, value.Id); window.ChangeAttachmentsDuringComposition(CurrentNote(id)?.Attachments); Sync.AfterEdit();
    }
    public async Task DownloadAttachment(Attachment value, NoteWindow window)
    {
        if (Sync.Files == null) return;
        var name = new string(value.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c).ToArray());
        try
        {
            var destination = await FilePicker.Save(name);
            if (destination == null || !AttachmentTargetAlive(window.Id, window)) return;
            window.SetAttachmentMessage("正在下载 · " + value.Name);
            await Sync.Files.Download(value, destination);
            if (AttachmentTargetAlive(window.Id, window)) window.SetAttachmentMessage("已下载 · " + value.Name);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or HttpRequestException or TaskCanceledException or InvalidOperationException or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
        { if (AttachmentTargetAlive(window.Id, window)) window.SetAttachmentMessage("下载失败 · 可重试"); AttachmentError(window, e.Message, "附件下载失败"); }
    }
    public void Delete(string id, Window? owner = null)
    {
        var note = CurrentNote(id); if (note == null || note.Deleted) return;
        if (MessageBox.Show(owner ?? Main, "删除这条便签？\n删除会同步到另一台电脑。", "删除便签", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        if (Editors.TryGetValue(id, out var editor)) editor.PrepareForClose();
        Store.Delete(id); Sync.AfterEdit();
    }
    public ContextMenu NoteMenu(string id, NoteWindow? window = null)
    {
        var note = CurrentNote(id); if (note == null) return new();
        var menu = Theme.ColorsMenu(id, note.Color, Color);
        var attach = new MenuItem { Header = "添加附件…", InputGestureText = "Ctrl+O", Icon = Theme.Glyph("\uE723", 13), IsEnabled = Sync.Files != null && !note.Deleted && !FilePicker.IsOpen };
        attach.Click += (_, _) => _ = AddAttachment(id, window); menu.Items.Add(new Separator()); menu.Items.Add(attach);
        var pin = new MenuItem { Header = note.Pinned ? "取消列表置顶" : "列表置顶", Icon = Theme.Glyph(note.Pinned ? "\uE77A" : "\uE718", 13) }; pin.Click += (_, _) => Pin(id); menu.Items.Insert(0, pin); menu.Items.Insert(1, new Separator());
        if (window != null)
        {
            var create = new MenuItem { Header = "新建便签", InputGestureText = "Ctrl+N", Icon = Theme.Glyph("\uE710", 13) }; create.Click += (_, _) => NewNote();
            var list = new MenuItem { Header = "便签列表", InputGestureText = "Ctrl+L", Icon = Theme.Glyph("\uE8FD", 13) }; list.Click += (_, _) => ShowList();
            menu.Items.Insert(0, create); menu.Items.Insert(1, list); menu.Items.Insert(2, new Separator());
            menu.Items.Add(new Separator());
            var top = new MenuItem { Header = "总在最前（仅本机窗口）", IsCheckable = true, IsChecked = window.Topmost };
            top.Click += (_, _) => { window.Topmost = top.IsChecked; SavePlacement(id, window); }; menu.Items.Add(top);
        }
        menu.Items.Add(new Separator());
        var remove = new MenuItem { Header = "删除便签…", Foreground = Theme.Brush("#B42318"), Icon = Theme.Glyph("\uE74D", 13, Theme.Brush("#B42318")) };
        remove.Click += (_, _) => Delete(id, window); menu.Items.Add(remove); return menu;
    }
    public void OpenNotice()
    {
        var state = Store.Snapshot(); var note = state.Visible().FirstOrDefault(n => state.DeleteConflictIds.Contains(n.Id)) ?? state.Visible().FirstOrDefault(n => n.ConflictOf != null); if (note != null) Open(note.Id);
    }
    public void SavePlacement(string id, Window window)
    {
        if (Preview) return;
        var rect = NativeMonitor.NormalBounds(window);
        if (rect == null) return;
        Store.SavePlacement(id, rect with { Topmost = window.Topmost });
    }
    void Restore(string id, Window window)
    {
        var state = Store.Snapshot(); state.Windows.TryGetValue(id, out var stored);
        var previous = Editors.Values.LastOrDefault(w => !ReferenceEquals(w, window));
        var cascade = previous == null ? null : NativeMonitor.NormalBounds(previous);
        window.Topmost = stored?.Topmost ?? false;
        window.SourceInitialized += (_, _) => NativeMonitor.Restore(window, stored, cascade);
    }
    public void TrayHint()
    {
        if (Preview || Store.Snapshot().TrayHintShown) return;
        tray?.ShowBalloonTip(4000, "SongNote 仍在托盘运行", "双击托盘图标打开便签列表；退出请用托盘菜单。", Forms.ToolTipIcon.Info); Store.MarkTrayHint();
    }
    void BuildTray()
    {
        trayMenu.Items.Clear();
        void Item(string label, Action action) { var item = trayMenu.Items.Add(label); item.Click += (_, _) => dispatcher.BeginInvoke(action); }
        Item("便签列表", () => ShowList()); Item("新建便签", NewNote); Item("立即同步", () => _ = SyncNow());
        var pinned = Store.Snapshot().Visible().Where(n => n.Pinned).ToArray();
        if (pinned.Length > 0)
        {
            trayMenu.Items.Add(new Forms.ToolStripSeparator());
            trayMenu.Items.Add(new Forms.ToolStripMenuItem("置顶便签") { Enabled = false });
        }
        foreach (var note in pinned) Item("   " + note.Title[..Math.Min(note.Title.Length, 32)], () => Open(note.Id));
        trayMenu.Items.Add(new Forms.ToolStripSeparator());
        Item(Startup.Registered ? "✓ 开机启动（已注册，系统可禁用）" : "开机启动（未注册）", () =>
        {
            try { Startup.Toggle(); } catch (Exception e) { MessageBox.Show(Main, e.Message, "无法更改开机启动"); }
        });
        trayMenu.Items.Add(new Forms.ToolStripSeparator()); Item("退出 SongNote", Quit);
    }
    public bool PrepareExit()
    {
        var open = Editors.Keys.ToArray();
        foreach (var editor in Editors.Values.ToArray()) { editor.PrepareForClose(); SavePlacement(editor.Id, editor); }
        SavePlacement("list", Main);
        if (!Store.RetrySave()) return false;
        return Store.FinishSession(open);
    }
    public void Quit()
    {
        if (!PrepareExit()) { MessageBox.Show(Main, "内容尚未安全保存，已取消退出。\n" + Store.SaveError, "本地保存失败", MessageBoxButton.OK, MessageBoxImage.Error); return; }
        Quitting = true; Application.Current.Shutdown();
    }
    public void Dispose() { FilePicker.Dispose(); Sync.Dispose(); clock.Stop(); if (tray != null) { tray.Visible = false; tray.Dispose(); } trayMenu.Dispose(); icon?.Dispose(); }
}

// Warm tray menu colours matching the in-app menus (the default renderer is blue-grey).
sealed class TrayColors : Forms.ProfessionalColorTable
{
    static readonly System.Drawing.Color Hover = System.Drawing.Color.FromArgb(0xEF, 0xEE, 0xE8), Line = System.Drawing.Color.FromArgb(0xD8, 0xD9, 0xD0);
    public override System.Drawing.Color MenuItemSelected => Hover;
    public override System.Drawing.Color MenuItemBorder => Hover;
    public override System.Drawing.Color MenuBorder => Line;
    public override System.Drawing.Color ToolStripDropDownBackground => System.Drawing.Color.White;
    public override System.Drawing.Color ImageMarginGradientBegin => System.Drawing.Color.White;
    public override System.Drawing.Color ImageMarginGradientMiddle => System.Drawing.Color.White;
    public override System.Drawing.Color ImageMarginGradientEnd => System.Drawing.Color.White;
    public override System.Drawing.Color SeparatorDark => System.Drawing.Color.FromArgb(0xE6, 0xE5, 0xDE);
    public override System.Drawing.Color SeparatorLight => System.Drawing.Color.White;
}
static class Startup
{
    const string Key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    public static bool Registered { get { using var key = Registry.CurrentUser.OpenSubKey(Key); return key?.GetValue("SongNote") is string value && value == Command; } }
    static string Command => "\"" + Environment.ProcessPath + "\"";
    public static void Toggle() { using var key = Registry.CurrentUser.CreateSubKey(Key); if (Registered) key.DeleteValue("SongNote", false); else key.SetValue("SongNote", Command); }
}
static class NativeMonitor
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct Point { public int X, Y; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct WindowPlacement
    { public int Length, Flags, ShowCommand; public Point Minimum, Maximum; public NativeRect Normal; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern nint MonitorFromPoint(Point point, uint flags);
    [System.Runtime.InteropServices.DllImport("shcore.dll")] static extern int GetDpiForMonitor(nint monitor, int type, out uint x, out uint y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetWindowRect(nint hwnd, out NativeRect rect);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetWindowPlacement(nint hwnd, ref WindowPlacement placement);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    static uint DpiForPoint(int x, int y)
    {
        try { return GetDpiForMonitor(MonitorFromPoint(new Point { X = x, Y = y }, 2), 0, out var dpi, out _) == 0 ? dpi : 96; } catch (DllNotFoundException) { return 96; }
    }
    public static Placement? NormalBounds(Window window)
    {
        var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle; if (handle == 0) return null;
        NativeRect rect;
        if (window.WindowState == WindowState.Normal) { if (!GetWindowRect(handle, out rect)) return null; }
        else
        {
            var placement = new WindowPlacement { Length = System.Runtime.InteropServices.Marshal.SizeOf<WindowPlacement>() };
            if (!GetWindowPlacement(handle, ref placement)) return null; rect = placement.Normal;
            var screen = Forms.Screen.FromRectangle(new System.Drawing.Rectangle(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top));
            rect.Left += screen.WorkingArea.Left - screen.Bounds.Left; rect.Right += screen.WorkingArea.Left - screen.Bounds.Left;
            rect.Top += screen.WorkingArea.Top - screen.Bounds.Top; rect.Bottom += screen.WorkingArea.Top - screen.Bounds.Top;
        }
        return rect.Right > rect.Left && rect.Bottom > rect.Top ? new(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top, window.Topmost) : null;
    }
    public static void Restore(Window window, Placement? saved, Placement? previous)
    {
        // Persist native physical coordinates; never mix screen pixels with WPF DIP.
        var primary = Forms.Screen.PrimaryScreen!.WorkingArea;
        int x = (int)(saved?.Left ?? previous?.Left + 24 ?? primary.Left + primary.Width / 2);
        int y = (int)(saved?.Top ?? previous?.Top + 24 ?? primary.Top + primary.Height / 2);
        var area = Forms.Screen.FromPoint(new System.Drawing.Point(x, y)).WorkingArea;
        double scale = DpiForPoint(x, y) / 96d;
        int width = Math.Min(area.Width, Math.Max((int)(window.MinWidth * scale), (int)(saved?.Width ?? window.Width * scale)));
        int height = Math.Min(area.Height, Math.Max((int)(window.MinHeight * scale), (int)(saved?.Height ?? window.Height * scale)));
        if (saved == null && previous == null) { x -= width / 2; y -= height / 2; }
        x = Math.Clamp(x, area.Left, area.Right - width); y = Math.Clamp(y, area.Top, area.Bottom - height);
        SetWindowPos(new System.Windows.Interop.WindowInteropHelper(window).Handle, 0, x, y, width, height, 0x14);
    }
}
