using System.ComponentModel;

namespace SongNote.Windows;

public sealed class NoteWindow : ChromeWindow
{
    readonly AppController controller;
    public string Id { get; private set; }
    public TextBox Editor { get; } = new()
    {
        AcceptsReturn = true, AcceptsTab = true, TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(16, 12, 16, 12), FontSize = 16,
        Foreground = new SolidColorBrush(Theme.Ink), IsUndoEnabled = true
    };
    public TextBlock Footer { get; } = Theme.Text("", 11);
    public Border Notice { get; } = new() { Padding = new Thickness(12, 5, 12, 5) };
    readonly TextBlock noticeText = Theme.Text("", 11);
    readonly Button noticeAction = new() { Padding = new Thickness(6, 2, 6, 2), Margin = new Thickness(6, 0, 0, 0) };
    readonly Button pin, sync;
    readonly RotateTransform spin = new();
    bool applying, composing, commitPending, suppressComposition;
    bool remoteClose;
    int compositionGeneration;
    Note? compositionBase;
    bool lastPinned;
    public bool Editing => IsActive && Editor.IsKeyboardFocusWithin;
    public NoteWindow(AppController controller, Note note)
    {
        this.controller = controller; Id = note.Id; Width = 380; Height = 420; MinWidth = 280; MinHeight = 240;
        Tools.Children.Add(Theme.Icon("\uE710", "新建便签（Ctrl+N）", controller.NewNote));
        Tools.Children.Add(Theme.Icon("\uE8FD", "便签列表（Ctrl+L）", () => controller.ShowList()));
        pin = Theme.Icon("\uE718", "列表置顶", () => controller.Pin(Id)); Tools.Children.Add(pin);
        var more = Theme.Icon("\uE712", "更多：颜色、总在最前、删除", () => { var menu = controller.NoteMenu(Id, this); menu.PlacementTarget = Tools; menu.IsOpen = true; }); Tools.Children.Add(more);
        var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        noticeText.TextWrapping = TextWrapping.Wrap; var notice = new DockPanel(); DockPanel.SetDock(noticeAction, Dock.Right); notice.Children.Add(noticeAction); notice.Children.Add(noticeText); Notice.Child = notice; grid.Children.Add(Notice);
        noticeAction.Click += (_, _) => { var state = controller.Store.Snapshot(); if (state.Notes.TryGetValue(Id, out var current) && current.Deleted) _ = controller.SyncNow(); else if (state.DeleteConflictIds.Contains(Id)) controller.Store.Acknowledge(Id); else if (state.Notes.TryGetValue(Id, out var n) && n.ConflictOf != null) controller.Open(n.ConflictOf); };
        Grid.SetRow(Editor, 1); grid.Children.Add(Editor);
        sync = Theme.Icon("\uE895", "立即同步（Ctrl+R）；本机保存失败时先重试", () => _ = controller.SyncNow()); sync.RenderTransform = spin; sync.RenderTransformOrigin = new Point(.5, .5);
        var footer = new Grid { Margin = new Thickness(12, 4, 10, 8) }; footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); footer.Children.Add(Footer); Grid.SetColumn(sync, 1); footer.Children.Add(sync); Grid.SetRow(footer, 2); grid.Children.Add(footer); Body.Content = grid;
        Editor.TextChanged += (_, _) => { if (!applying && !composing && !commitPending && !suppressComposition) SaveText(); };
        Editor.AddHandler(TextCompositionManager.PreviewTextInputStartEvent, new TextCompositionEventHandler((_, e) =>
        {
            if (suppressComposition) return;
            if (commitPending) { composing = false; commitPending = false; SaveText(); compositionBase = null; }
            composing = true; compositionBase ??= controller.CurrentNote(Id);
            compositionGeneration++;
        }), true);
        Editor.AddHandler(TextCompositionManager.PreviewTextInputUpdateEvent, new TextCompositionEventHandler((_, e) =>
        {
            if (!suppressComposition) { composing = true; compositionBase ??= controller.CurrentNote(Id); }
        }), true);
        Editor.AddHandler(TextCompositionManager.PreviewTextInputEvent, new TextCompositionEventHandler((_, e) =>
        {
            if (suppressComposition) return;
            commitPending = true;
            int generation = compositionGeneration;
            Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
            {
                if (suppressComposition || generation != compositionGeneration) return; composing = false; commitPending = false; SaveText(); compositionBase = null; Refresh();
            }));
        }), true);
        Editor.PreviewKeyDown += (_, e) =>
        {
            if ((e.Key == Key.Escape || e.ImeProcessedKey == Key.Escape) && composing)
            {
                int generation = ++compositionGeneration;
                Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => { if (generation != compositionGeneration) return; composing = false; commitPending = false; compositionBase = null; Refresh(); }));
            }
        };
        Editor.GotKeyboardFocus += (_, _) => controller.Refresh(); Editor.LostKeyboardFocus += (_, _) => controller.Refresh(true);
        Activated += (_, _) => Motion.Fade(Tools, Tools.Opacity, 1); Deactivated += (_, _) => { Motion.Fade(Tools, Tools.Opacity, .55); controller.Refresh(true); };
        Closing += CloseRequested; Closed += (_, _) => { Motion.Spin(spin, false); controller.NoteClosed(Id); };
        Loaded += (_, _) => SetCompactCaption(ActualWidth < 360); SizeChanged += (_, _) => SetCompactCaption(ActualWidth < 360);
        lastPinned = note.Pinned; Refresh();
    }
    public void ChangeColorDuringComposition(string color) { if (compositionBase != null) compositionBase = compositionBase with { Color = color }; }
    public void ChangePinDuringComposition(bool pinned) { if (compositionBase != null) compositionBase = compositionBase with { Pinned = pinned }; }
    public void Remap(string id, Receipt[] receipts, Change[] sent)
    {
        if (Id != id)
        {
            Id = id; if (compositionBase != null) compositionBase = compositionBase with { Id = id, Revision = controller.CurrentNote(id)?.Revision ?? compositionBase.Revision, ConflictOf = controller.CurrentNote(id)?.ConflictOf };
        }
        if (compositionBase != null)
            foreach (var receipt in receipts.Where(r => r.Status == "applied" && r.NoteId == Id))
            {
                var op = sent.FirstOrDefault(c => c.OpId == receipt.OpId);
                if (op != null && !op.Deleted && op.NoteId == compositionBase.Id && op.BaseRevision == compositionBase.Revision)
                    compositionBase = compositionBase with { Revision = receipt.Revision };
            }
    }
    public void SaveText()
    {
        if (applying || composing || suppressComposition) return;
        var baseline = compositionBase ?? controller.CurrentNote(Id); if (baseline == null || Editor.Text == baseline.Text) return;
        if (Editor.Text.Length > 100000) { System.Media.SystemSounds.Beep.Play(); ApplyText(baseline.Text); return; }
        controller.Store.SetText(Id, Editor.Text, baseline); controller.Sync.AfterEdit();
    }
    void ApplyText(string text)
    {
        var selection = Math.Min(Editor.SelectionStart, text.Length); applying = true; Editor.Text = text; Editor.Select(selection, 0); applying = false;
    }
    public void PrepareForClose()
    {
        compositionGeneration++;
        if (commitPending)
        {
            composing = false; commitPending = false; SaveText(); compositionBase = null;
        }
        else if (composing)
        {
            suppressComposition = true;
            Keyboard.ClearFocus(); composing = false; compositionBase = null;
            ApplyText(controller.CurrentNote(Id)?.Text ?? ""); suppressComposition = false;
        }
        else SaveText();
    }
    void CloseRequested(object? sender, CancelEventArgs e)
    {
        if (!remoteClose && !controller.Quitting) PrepareForClose();
        controller.SavePlacement(Id, this);
        if (!controller.Store.LastSaved || !controller.Store.DiscardDraft(Id))
        { e.Cancel = true; MessageBox.Show(this, "内容尚未安全保存，请点击立即同步重试本地保存。\n" + controller.Store.SaveError, "本地保存失败", MessageBoxButton.OK, MessageBoxImage.Error); }
    }
    public void Refresh()
    {
        var state = controller.Store.Snapshot(); if (!state.Notes.TryGetValue(Id, out var note)) return;
        if (note.Deleted && controller.Store.LastSaved && !composing && !commitPending && compositionBase == null)
        { if (IsLoaded) { remoteClose = true; Close(); if (controller.Editors.ContainsKey(Id)) remoteClose = false; } return; }
        Editor.IsReadOnly = note.Deleted && !composing && !commitPending;
        Title = note.Title + (note.ConflictOf == null ? "" : " · 冲突副本");
        if (!composing && !commitPending && compositionBase == null && Editor.Text != note.Text) ApplyText(note.Text);
        Motion.Color(Surface, Theme.Paper(note.Color).Color);
        pin.Foreground = note.Pinned ? Brushes.White : new SolidColorBrush(Theme.Ink); pin.Background = note.Pinned ? new SolidColorBrush(Theme.Ink) : Brushes.Transparent;
        pin.ToolTip = note.Pinned ? "取消列表置顶" : "列表置顶";
        pin.Content = Theme.PinIcon(note.Pinned); System.Windows.Automation.AutomationProperties.SetName(pin, (string)pin.ToolTip);
        if (lastPinned != note.Pinned) { var scale = new ScaleTransform(1, 1); pin.RenderTransform = scale; pin.RenderTransformOrigin = new Point(.5, .5); Motion.Animate(scale, ScaleTransform.ScaleXProperty, 1.1, 1, 220); Motion.Animate(scale, ScaleTransform.ScaleYProperty, 1.1, 1, 220); } lastPinned = note.Pinned;
        if (note.Deleted && !composing && !commitPending)
        { noticeText.Text = "便签已标记删除，本机保存失败，暂不可编辑"; noticeAction.Content = "重试保存"; noticeAction.IsEnabled = true; Notice.Visibility = Visibility.Visible; }
        else if (state.DeleteConflictIds.Contains(Id))
        { noticeText.Text = "删除未执行：另一端有新内容，已保留"; noticeAction.Content = "知道了"; noticeAction.IsEnabled = true; Notice.Visibility = Visibility.Visible; }
        else if (note.ConflictOf != null)
        {
            bool available = state.Notes.TryGetValue(note.ConflictOf, out var original) && !original.Deleted;
            noticeText.Text = available ? "这是冲突副本，已保留两份内容" : "这是冲突副本，原便签已删除或不可用";
            noticeAction.Content = "查看原件"; noticeAction.IsEnabled = available; Notice.Visibility = Visibility.Visible;
        }
        else Notice.Visibility = Visibility.Collapsed;
        bool waiting = state.Pending.ContainsKey(Id) || state.FrozenBatch.Any(c => c.NoteId == Id);
        Footer.Text = !controller.Store.LastSaved ? "本地保存失败，请勿退出" : state.DraftIds.Contains(Id) ? "本机草稿 · 空白关窗自动丢弃" : controller.Sync.Syncing && controller.Sync.ShowProgress ? "正在同步…" : controller.Sync.Error ?? (waiting ? "已保存 · 等待同步" : controller.Sync.Status);
        Footer.Foreground = !controller.Store.LastSaved ? Brushes.Firebrick : controller.Sync.Error == null ? Theme.Muted : Brushes.DarkOrange;
        Footer.ToolTip = controller.Store.SaveError ?? "每次正式输入自动保存到本机；已同步表示服务器已确认接收，另一台电脑须运行应用并联网。";
        sync.IsEnabled = !controller.Sync.Syncing; Motion.Spin(spin, controller.Sync.Syncing && controller.Sync.ShowProgress);
    }
}
