using System.ComponentModel;
using System.Windows.Controls.Primitives;

namespace SongNote.Windows;

// One line of file chips under the text; chips that do not fit collapse into a "+N" chip.
public sealed class AttachmentStrip : Panel
{
    public const double ChipHeight = 24, Gap = 6, MaxChip = 150;
    public Button Overflow { get; }
    public int Shown { get; private set; }
    public AttachmentStrip(Button overflow) { Overflow = overflow; Children.Add(overflow); ClipToBounds = true; }
    List<UIElement> Chips => Children.Cast<UIElement>().Where(c => c != Overflow).ToList();
    void SetOverflow(int count)
    {
        var text = "+" + count; if (!Equals(Overflow.Content, text)) Overflow.Content = text;
        Overflow.Measure(new Size(80, ChipHeight));
    }
    protected override Size MeasureOverride(Size available)
    {
        var chips = Chips; double x = 0; int shown = 0;
        foreach (var chip in chips) chip.Measure(new Size(MaxChip, ChipHeight));
        for (int i = 0; i < chips.Count; i++)
        {
            int remaining = chips.Count - i - 1; double reserve = 0;
            if (remaining > 0) { SetOverflow(remaining); reserve = Overflow.DesiredSize.Width + Gap; }
            double width = Math.Min(MaxChip, chips[i].DesiredSize.Width);
            if (x + width + reserve > available.Width && !(i == 0 && remaining == 0)) break;
            x += width + Gap; shown++;
        }
        Shown = shown; SetOverflow(chips.Count - shown);
        for (int i = 0; i < chips.Count; i++) { var visible = i < shown ? Visibility.Visible : Visibility.Hidden; if (chips[i].Visibility != visible) chips[i].Visibility = visible; }
        var overflow = shown < chips.Count ? Visibility.Visible : Visibility.Hidden; if (Overflow.Visibility != overflow) Overflow.Visibility = overflow;
        return new Size(double.IsInfinity(available.Width) ? x : available.Width, chips.Count == 0 ? 0 : ChipHeight);
    }
    protected override Size ArrangeOverride(Size final)
    {
        double x = 0; var chips = Chips;
        for (int i = 0; i < chips.Count; i++)
        {
            if (i < Shown) { double width = Math.Min(Math.Min(MaxChip, chips[i].DesiredSize.Width), final.Width); chips[i].Arrange(new Rect(x, 0, width, ChipHeight)); x += width + Gap; }
            else chips[i].Arrange(new Rect(0, 0, 0, 0));
        }
        Overflow.Arrange(Shown < chips.Count ? new Rect(x, 0, Overflow.DesiredSize.Width, ChipHeight) : new Rect(0, 0, 0, 0));
        return final;
    }
}

public sealed class NoteWindow : ChromeWindow
{
    readonly AppController controller;
    public string Id { get; private set; }
    public TextBox Editor { get; } = new()
    {
        AcceptsReturn = true, AcceptsTab = true, TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(14, 6, 14, 8), FontSize = 15,
        Foreground = new SolidColorBrush(Theme.Ink), IsUndoEnabled = true
    };
    public TextBlock Footer { get; } = Theme.Text("", 11);
    public Border Notice { get; } = new() { Margin = new Thickness(10, 0, 10, 4), Padding = new Thickness(10, 5, 5, 5), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
    readonly TextBlock noticeText = Theme.Text("", 12), noticeIcon = Theme.Glyph("", 14);
    readonly Button noticeAction = new() { Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(8, 2, 8, 2), VerticalAlignment = VerticalAlignment.Center };
    readonly Button pin, sync, more;
    readonly RotateTransform spin = new();
    bool applying, composing, commitPending, suppressComposition;
    bool remoteClose;
    int compositionGeneration;
    Note? compositionBase;
    bool lastPinned;
    public bool Editing => IsActive && Editor.IsKeyboardFocusWithin;
    public Button PinButton => pin;
    public AttachmentStrip AttachmentPanel { get; }
    Attachment[] attachmentValues = [];
    readonly HashSet<string> downloading = [];
    string attachmentSignature = "";
    string localAttachmentMessage = "";
    public NoteWindow(AppController controller, Note note) : base(maximizable: false)
    {
        this.controller = controller; Id = note.Id; Width = 380; Height = 420; MinWidth = 280; MinHeight = 240;
        // Only pin and "more" stay in the titlebar; new note and the list live in the menu and Ctrl+N / Ctrl+L.
        pin = Theme.Icon("\uE718", "列表置顶", () => controller.Pin(Id)); Tools.Children.Add(pin);
        more = Theme.Icon("\uE712", "更多：新建、列表、颜色、附件、总在最前、删除", () => ShowMore()); Tools.Children.Add(more);
        var overflow = new Button { Style = Theme.Style("SoftButton"), Height = AttachmentStrip.ChipHeight, Padding = new Thickness(8, 0, 8, 0) };
        overflow.Click += (_, _) => ShowAllAttachments(overflow);
        AttachmentPanel = new AttachmentStrip(overflow) { Margin = new Thickness(14, 2, 14, 2), Visibility = Visibility.Collapsed };
        var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        noticeText.TextWrapping = TextWrapping.Wrap; noticeText.Foreground = new SolidColorBrush(Theme.Ink); noticeAction.Style = Theme.Style("SoftButton");
        noticeIcon.Margin = new Thickness(0, 1, 8, 0); noticeIcon.VerticalAlignment = VerticalAlignment.Top;
        var notice = new DockPanel(); DockPanel.SetDock(noticeIcon, Dock.Left); DockPanel.SetDock(noticeAction, Dock.Right);
        notice.Children.Add(noticeIcon); notice.Children.Add(noticeAction); notice.Children.Add(noticeText); Notice.Child = notice; grid.Children.Add(Notice);
        noticeAction.Click += (_, _) => { var state = controller.Store.Snapshot(); if (state.Notes.TryGetValue(Id, out var current) && current.Deleted) _ = controller.SyncNow(); else if (state.DeleteConflictIds.Contains(Id)) controller.Store.Acknowledge(Id); else if (state.Notes.TryGetValue(Id, out var n) && n.ConflictOf != null) controller.Open(n.ConflictOf); };
        // A calmer writing surface: about 1.6x line height for 15px Chinese text.
        TextBlock.SetLineHeight(Editor, 24); TextBlock.SetLineStackingStrategy(Editor, LineStackingStrategy.BlockLineHeight);
        Grid.SetRow(Editor, 1); grid.Children.Add(Editor);
        Grid.SetRow(AttachmentPanel, 2); grid.Children.Add(AttachmentPanel);
        sync = Theme.Icon("\uE895", "立即同步（Ctrl+R）；本机保存失败时先重试", () => _ = controller.SyncNow()); sync.RenderTransform = spin; sync.RenderTransformOrigin = new Point(.5, .5); sync.Foreground = Theme.Muted;
        Footer.Foreground = Theme.Faint;
        var footer = new Grid { Margin = new Thickness(14, 4, 10, 8), MinHeight = 28 }; footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); footer.Children.Add(Footer); Grid.SetColumn(sync, 1); footer.Children.Add(sync); Grid.SetRow(footer, 3); grid.Children.Add(footer); Body.Content = grid;
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
        Activated += (_, _) => Motion.Fade(Tools, Tools.Opacity, 1); Deactivated += (_, _) => { Motion.Fade(Tools, Tools.Opacity, .35); controller.Refresh(true); };
        Closing += CloseRequested; Closed += (_, _) => { Motion.Spin(spin, false); controller.NoteClosed(Id); };
        lastPinned = note.Pinned; Refresh();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.O && Keyboard.Modifiers == ModifierKeys.Control)
            { e.Handled = true; _ = controller.AddAttachment(Id, this); }
        };
    }
    public ContextMenu ShowMore()
    {
        // Right-align the menu under the "more" button instead of opening at the mouse pointer.
        var menu = controller.NoteMenu(Id, this); menu.PlacementTarget = more; menu.Placement = PlacementMode.Custom;
        menu.CustomPopupPlacementCallback = (popup, target, _) => [new CustomPopupPlacement(new Point(target.Width - popup.Width + 10, target.Height + 2), PopupPrimaryAxis.Horizontal)];
        menu.IsOpen = true; return menu;
    }
    void SetNotice(string kind, string text, string action, bool enabled)
    {
        (string glyph, string icon, string fill, string line) = kind switch
        {
            "danger" => ("\uEA39", "#B42318", "#FBE6E3", "#E9B4AD"),
            "warning" => ("\uE7BA", "#8A5A00", "#FDF1DA", "#E7CA8A"),
            _ => ("\uE8C8", "#303633", "#B3FFFFFF", "#33303633")
        };
        noticeIcon.Text = glyph; noticeIcon.Foreground = Theme.Brush(icon); Notice.Background = Theme.Brush(fill); Notice.BorderBrush = Theme.Brush(line);
        noticeText.Text = text; noticeAction.Content = action; noticeAction.IsEnabled = enabled; Notice.Visibility = Visibility.Visible;
        System.Windows.Automation.AutomationProperties.SetName(Notice, text);
        Notice.ToolTip = kind switch
        {
            "danger" => "本机保存失败，删除还没有生效，正文暂时只读。点「重试保存」再次写入本机。",
            "warning" => "你删除了这条便签，但另一台电脑在此之前改过它，所以保留了新内容。点「知道了」关闭提示。",
            _ => "两台电脑同时改了同一条便签，这是另存的一份；两份内容都在，可以对照后删掉不需要的。"
        };
    }
    public void ChangeColorDuringComposition(string color) { if (compositionBase != null) compositionBase = compositionBase with { Color = color }; }
    public void ChangePinDuringComposition(bool pinned) { if (compositionBase != null) compositionBase = compositionBase with { Pinned = pinned }; }
    public void ChangeAttachmentsDuringComposition(Attachment[]? values) { if (compositionBase != null) compositionBase = compositionBase with { Attachments = values == null ? null : [.. values] }; }
    public void SetAttachmentMessage(string message) { localAttachmentMessage = message; Refresh(); }
    static string SizeLabel(long size) => size < 1024 ? $"{size} B" : size < 1024 * 1024 ? $"{size / 1024d:0.#} KiB" : $"{size / (1024d * 1024):0.#} MiB";
    static string FileGlyph(string name) => Path.GetExtension(name).ToLowerInvariant() switch
    {
        ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" or ".webp" or ".heic" => "\uEB9F",
        ".zip" or ".rar" or ".7z" or ".gz" => "\uF012",
        _ => "\uE8A5"
    };
    void RefreshAttachments(Note note)
    {
        var values = note.Attachments ?? []; attachmentValues = values;
        AttachmentPanel.Visibility = values.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var signature = ProtocolJson.Encode(values);
        if (signature == attachmentSignature) return;
        attachmentSignature = signature;
        foreach (var chip in AttachmentPanel.Children.OfType<Button>().Where(b => b != AttachmentPanel.Overflow).ToArray()) AttachmentPanel.Children.Remove(chip);
        foreach (var value in values)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(Theme.Glyph(FileGlyph(value.Name), 12, Theme.Muted));
            content.Children.Add(new TextBlock { Text = value.Name, Margin = new Thickness(5, 0, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = AttachmentStrip.MaxChip - 40, VerticalAlignment = VerticalAlignment.Center });
            var chip = new Button { Style = Theme.Style("SoftButton"), Height = AttachmentStrip.ChipHeight, Padding = new Thickness(8, 0, 8, 0), Content = content,
                ToolTip = $"{value.Name} · {SizeLabel(value.Size)}（点击下载或移除）" };
            System.Windows.Automation.AutomationProperties.SetName(chip, "附件 " + value.Name);
            chip.Click += (_, _) => { var menu = AttachmentMenu(value); menu.PlacementTarget = chip; menu.Placement = PlacementMode.Top; menu.IsOpen = true; };
            AttachmentPanel.Children.Insert(AttachmentPanel.Children.Count - 1, chip);
        }
        AttachmentPanel.InvalidateMeasure();
    }
    ContextMenu AttachmentMenu(Attachment value)
    {
        var menu = new ContextMenu();
        foreach (var item in AttachmentItems(value)) menu.Items.Add(item);
        return menu;
    }
    IEnumerable<object> AttachmentItems(Attachment value)
    {
        yield return new MenuItem { Header = $"{value.Name} · {SizeLabel(value.Size)}", Style = Theme.Style("SectionMenuHeader"), IsEnabled = false };
        bool busy = downloading.Contains(value.Id);
        var download = new MenuItem { Header = busy ? "正在下载…" : "下载…", Icon = Theme.Glyph("\uE896", 13), IsEnabled = !busy && controller.Sync.Files != null };
        download.Click += async (_, _) =>
        {
            if (!downloading.Add(value.Id)) return;
            try { await controller.DownloadAttachment(value, this); } finally { downloading.Remove(value.Id); }
        };
        yield return download;
        var remove = new MenuItem { Header = "移除…", Icon = Theme.Glyph("\uE738", 13), IsEnabled = controller.CurrentNote(Id) is { Deleted: false } };
        remove.Click += (_, _) => controller.RemoveAttachment(Id, value, this);
        yield return remove;
    }
    void ShowAllAttachments(Button anchor)
    {
        var menu = new ContextMenu();
        foreach (var value in attachmentValues)
        {
            var item = new MenuItem { Header = value.Name, Icon = Theme.Glyph(FileGlyph(value.Name), 13) };
            foreach (var child in AttachmentItems(value)) item.Items.Add(child);
            menu.Items.Add(item);
        }
        menu.PlacementTarget = anchor; menu.Placement = PlacementMode.Top; menu.IsOpen = true;
    }
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
        RefreshAttachments(note);
        Title = note.Title + (note.ConflictOf == null ? "" : " · 冲突副本");
        if (!composing && !commitPending && compositionBase == null && Editor.Text != note.Text) ApplyText(note.Text);
        Motion.Color(Surface, Theme.Paper(note.Color).Color);
        // Pinned: filled pin on a tint of the note colour; never a heavy black block on pastel paper.
        pin.Background = note.Pinned ? Theme.Tint(note.Color, 0x66) : Brushes.Transparent;
        pin.ToolTip = note.Pinned ? "已列表置顶（点击取消）" : "列表置顶";
        pin.Content = note.Pinned ? "\uE841" : "\uE718"; System.Windows.Automation.AutomationProperties.SetName(pin, note.Pinned ? "取消列表置顶" : "列表置顶");
        if (lastPinned != note.Pinned) { var scale = new ScaleTransform(1, 1); pin.RenderTransform = scale; pin.RenderTransformOrigin = new Point(.5, .5); Motion.Animate(scale, ScaleTransform.ScaleXProperty, 1.1, 1, 220); Motion.Animate(scale, ScaleTransform.ScaleYProperty, 1.1, 1, 220); } lastPinned = note.Pinned;
        if (note.Deleted && !composing && !commitPending)
            SetNotice("danger", "保存失败，删除未生效", "重试保存", true);
        else if (state.DeleteConflictIds.Contains(Id))
            SetNotice("warning", "删除未执行：另一端有新内容", "知道了", true);
        else if (note.ConflictOf != null)
        {
            bool available = state.Notes.TryGetValue(note.ConflictOf, out var original) && !original.Deleted;
            SetNotice("info", available ? "冲突副本 · 两份内容都已保留" : "冲突副本 · 原便签已删除", "查看原件", available);
        }
        else Notice.Visibility = Visibility.Collapsed;
        bool waiting = state.Pending.ContainsKey(Id) || state.FrozenBatch.Any(c => c.NoteId == Id);
        // Footer is quiet: the edit time when everything is synced, otherwise the state that needs attention.
        string? syncText = state.DraftIds.Contains(Id) ? "本机草稿 · 空白关窗自动丢弃" : controller.Sync.Syncing && controller.Sync.ShowProgress ? "正在同步…" : controller.Sync.Error ?? (waiting ? "已保存 · 等待同步" : controller.Sync.LastSyncAt == null ? controller.Sync.Status : null);
        string? message = controller.Sync.AttachmentStatus ?? (localAttachmentMessage.Length > 0 ? localAttachmentMessage : null);
        Footer.Text = !controller.Store.LastSaved ? "本地保存失败，请勿退出" : message ?? Theme.Timestamp(note.UpdatedAt) + (syncText == null ? "" : " · " + syncText);
        bool quiet = controller.Store.LastSaved && message == null && syncText == null;
        Footer.Foreground = !controller.Store.LastSaved ? Brushes.Firebrick : controller.Sync.Error == null ? Theme.Faint : Brushes.DarkOrange;
        Footer.ToolTip = controller.Store.SaveError ?? "每次正式输入自动保存到本机；已同步表示服务器已确认接收，另一台电脑须运行应用并联网。";
        sync.IsEnabled = !controller.Sync.Syncing; Motion.Spin(spin, controller.Sync.Syncing && controller.Sync.ShowProgress);
        sync.Visibility = quiet ? Visibility.Hidden : Visibility.Visible;
        var tint = Theme.Accent(note.Color).Color; var toolTint = Color.FromRgb((byte)(tint.R * .35 + Theme.Ink.R * .65), (byte)(tint.G * .35 + Theme.Ink.G * .65), (byte)(tint.B * .35 + Theme.Ink.B * .65));
        pin.Foreground = new SolidColorBrush(toolTint); more.Foreground = new SolidColorBrush(toolTint);
    }
}
