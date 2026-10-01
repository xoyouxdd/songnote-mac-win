using System.Windows.Automation;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Shell;

namespace SongNote.Windows;

public class ChromeWindow : Window
{
    public Grid LayoutRoot { get; } = new();
    protected StackPanel Heading { get; } = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    protected StackPanel Tools { get; } = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    protected ContentControl Body { get; } = new();
    protected SolidColorBrush Surface { get; } = Theme.Brush("#F6F5F0");
    readonly Border frame;
    readonly bool maximizable;
    public bool CanMaximize => maximizable;
    public int CaptionButtonCount { get; }
    public ChromeWindow(bool maximizable = true)
    {
        this.maximizable = maximizable;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize; Background = Surface;
        FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI"); Foreground = new SolidColorBrush(Theme.Ink);
        UseLayoutRounding = true; SnapsToDevicePixels = true;
        // A one-pixel DWM frame keeps the system shadow; Windows 11 then rounds the corners natively.
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 36, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0, 0, 0, 1), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false });
        LayoutRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) }); LayoutRoot.RowDefinitions.Add(new RowDefinition());
        var header = new Grid { Margin = new Thickness(12, 0, 4, 0) };
        header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Heading); Grid.SetColumn(Tools, 1); header.Children.Add(Tools);
        // Separate the app's own tools from the window buttons.
        var system = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        system.Children.Add(Theme.Icon("\uE921", "最小化", () => SystemCommands.MinimizeWindow(this), 36));
        if (maximizable)
            system.Children.Add(Theme.Icon("\uE922", "最大化 / 还原", () => { if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this); else SystemCommands.MaximizeWindow(this); }, 36));
        system.Children.Add(Theme.Icon("\uE8BB", "关闭窗口", () => SystemCommands.CloseWindow(this), 36, "CloseButton"));
        foreach (Button button in system.Children) button.FontSize = 12;
        CaptionButtonCount = system.Children.Count;
        Grid.SetColumn(system, 2); header.Children.Add(system); LayoutRoot.Children.Add(header);
        Grid.SetRow(Body, 1); LayoutRoot.Children.Add(Body);
        frame = new Border { BorderBrush = Theme.Brush("#D8D9D0"), BorderThickness = new Thickness(NativeFrame.RoundedByDwm ? 0 : 1), Child = LayoutRoot, Background = Surface };
        Content = frame;
        SourceInitialized += (_, _) => NativeFrame.Apply(this, maximizable);
        StateChanged += (_, _) => frame.Padding = WindowState == WindowState.Maximized ? NativeFrame.MaximizedInset : new Thickness(0);
        Loaded += (_, _) => { if (Motion.Enabled) { Motion.Fade(LayoutRoot, 0, 1); var scale = new ScaleTransform(1, 1); LayoutRoot.RenderTransform = scale; LayoutRoot.RenderTransformOrigin = new Point(0.5, 0.5); Motion.Animate(scale, ScaleTransform.ScaleXProperty, .98, 1); Motion.Animate(scale, ScaleTransform.ScaleYProperty, .98, 1); } };
        PreviewKeyDown += (_, e) =>
        {
            if (Keyboard.Modifiers != ModifierKeys.Control) return;
            switch (e.Key)
            {
                case Key.N: AppController.Current.NewNote(); break;
                case Key.L: AppController.Current.ShowList(); break;
                case Key.F: AppController.Current.ShowList(true); break;
                case Key.R: _ = AppController.Current.SyncNow(); break;
                case Key.W: Close(); break;
                default: return;
            }
            e.Handled = true;
        };
    }
}

static class NativeFrame
{
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLongPtr(nint hwnd, int index);
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern nint SetWindowLongPtr(nint hwnd, int index, nint value);
    // Windows 11 (build 22000+) draws rounded corners and a 1px border itself.
    public static bool RoundedByDwm { get; } = Environment.OSVersion.Version.Build >= 22000;
    // WindowChrome lets a maximised window overhang the work area by the resize frame.
    public static Thickness MaximizedInset
    {
        get
        {
            var frame = SystemParameters.WindowResizeBorderThickness; double padding = SystemParameters.WindowNonClientFrameThickness.Left - frame.Left;
            double inset = frame.Left + Math.Max(0, padding);
            return new Thickness(inset, frame.Top + Math.Max(0, padding), inset, frame.Bottom + Math.Max(0, padding));
        }
    }
    public static void Apply(Window window, bool maximizable)
    {
        var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle; if (handle == 0) return;
        if (RoundedByDwm)
        {
            int round = 2, border = 0x00D0D9D8; // DWMWCP_ROUND; COLORREF of #D8D9D0
            DwmSetWindowAttribute(handle, 33, ref round, sizeof(int)); DwmSetWindowAttribute(handle, 34, ref border, sizeof(int));
        }
        // Sticky notes resize freely but never maximise (also blocks caption double-click and Win+Up).
        if (!maximizable) SetWindowLongPtr(handle, -16, GetWindowLongPtr(handle, -16) & ~(nint)0x00010000);
    }
}

public sealed class ResponsiveNotesPanel : Panel
{
    public int Columns { get; private set; } = 1;
    Dictionary<UIElement, Rect> previous = [];
    protected override Size MeasureOverride(Size available)
    {
        double width = double.IsInfinity(available.Width) ? Math.Max(360, ActualWidth) : available.Width;
        Columns = width >= 620 ? 2 : 1;
        double column = Math.Max(0, (width - (Columns - 1) * 8) / Columns); int live = 0;
        foreach (UIElement child in InternalChildren) { child.Measure(new Size(column, 84)); if (Live(child)) live++; }
        int rows = (live + Columns - 1) / Columns;
        return new Size(width, Math.Max(0, rows * 92 - 8));
    }
    protected override Size ArrangeOverride(Size final)
    {
        double column = Math.Max(0, (final.Width - (Columns - 1) * 8) / Columns); var next = new Dictionary<UIElement, Rect>(); int slot = 0;
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            var child = InternalChildren[i];
            Rect rect;
            if (!Live(child))
            {
                if (!previous.TryGetValue(child, out rect)) { var offset = VisualTreeHelper.GetOffset(child); rect = new Rect(offset.X, offset.Y, column, 84); }
            }
            else { rect = new Rect((slot % Columns) * (column + 8), (slot / Columns) * 92, column, 84); slot++; }
            child.Arrange(rect); next[child] = rect;
            if (Motion.Enabled && previous.TryGetValue(child, out var old) && old.TopLeft != rect.TopLeft)
            {
                var transform = new TranslateTransform(); child.RenderTransform = transform;
                Motion.Animate(transform, TranslateTransform.XProperty, old.X - rect.X, 0);
                Motion.Animate(transform, TranslateTransform.YProperty, old.Y - rect.Y, 0);
            }
            else if (!previous.ContainsKey(child)) Motion.Fade(child, 0, 1);
        }
        previous = next; return final;
    }
    static bool Live(UIElement child) => NoteCard.Descendant<NoteCard>(child)?.Removing != true;
}

public sealed class NoteCard : UserControl
{
    readonly Border surface = new() { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), ClipToBounds = true };
    readonly Border stripe = new() { Width = 4, HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock title = Theme.Text("", 15, true), preview = Theme.Text("", 13), hint = Theme.Text("", 11);
    readonly SolidColorBrush paper = Theme.Brush("#FFF5C9");
    bool pressed, hovered, selected, wasRemoving;
    public bool Removing { get; private set; }
    NoteViewModel? model;
    public NoteCard()
    {
        Height = 84; surface.Background = paper; var grid = new Grid(); grid.Children.Add(stripe);
        var lines = new Grid { Margin = new Thickness(14, 8, 12, 8) };
        lines.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); lines.RowDefinitions.Add(new RowDefinition()); lines.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        lines.Children.Add(title); Grid.SetRow(preview, 1); lines.Children.Add(preview); Grid.SetRow(hint, 2); lines.Children.Add(hint);
        grid.Children.Add(lines); surface.Child = grid; Content = surface;
        DataContextChanged += (_, _) => { if (model != null) model.PropertyChanged -= ModelChanged; model = DataContext as NoteViewModel; if (model != null) model.PropertyChanged += ModelChanged; Refresh(); };
        Unloaded += (_, _) => { if (model != null) model.PropertyChanged -= ModelChanged; };
        Loaded += (_, _) => { if (model != null) { model.PropertyChanged -= ModelChanged; model.PropertyChanged += ModelChanged; } Refresh(); };
        AddHandler(Selector.SelectedEvent, new RoutedEventHandler((_, _) => Selection(true)));
        AddHandler(Selector.UnselectedEvent, new RoutedEventHandler((_, _) => Selection(false)));
        MouseEnter += (_, _) => { hovered = true; UpdateBorder(); if (model != null) Motion.Color(paper, Hover(Theme.Paper(model.Note.Color).Color)); };
        MouseLeave += (_, _) => { pressed = false; hovered = false; UpdateBorder(); if (model != null) Motion.Color(paper, Theme.Paper(model.Note.Color).Color); };
        PreviewMouseLeftButtonDown += (_, _) => { if (model?.Removing != false) return; pressed = true; var item = Ancestor<ListBoxItem>(this); if (item != null) { item.IsSelected = true; item.Focus(); } };
        MouseLeftButtonUp += (_, e) => { bool open = pressed && IsMouseOver && model?.Removing == false; pressed = false; if (open) AppController.Current.Open(model!.Id); e.Handled = true; };
        ContextMenuOpening += (_, _) => { if (model != null) ContextMenu = AppController.Current.NoteMenu(model.Id); };
        ContextMenu = new ContextMenu();
    }
    void ModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => Refresh();
    void Selection(bool value) { selected = value; UpdateBorder(); }
    void UpdateBorder()
    {
        surface.BorderThickness = new Thickness(selected ? 2 : 1);
        surface.BorderBrush = selected ? new SolidColorBrush(Theme.Ink) : Theme.Tint(model?.Note.Color ?? "gray", (byte)(hovered ? 0xA0 : 0x55));
    }
    public void UpdateSelection(bool selected) => Selection(selected);
    public bool SelectionHighlighted => surface.BorderThickness.Left == 2;
    void Refresh()
    {
        if (model == null) return;
        var query = AppController.Current == null ? "" : AppController.Current.Model.Query.Trim();
        Mark(title, model.Title, query); Mark(preview, model.Preview, query); hint.Text = model.Hint; hint.ToolTip = model.Hint;
        stripe.Background = Theme.Accent(model.Note.Color); UpdateBorder();
        var color = Theme.Paper(model.Note.Color).Color; Motion.Color(paper, hovered ? Hover(color) : color);
        AutomationProperties.SetName(this, model.Title + "，" + model.Hint);
        IsHitTestVisible = !model.Removing;
        if (Removing != model.Removing) { Removing = model.Removing; Ancestor<ResponsiveNotesPanel>(this)?.InvalidateMeasure(); }
        if (model.Removing) Motion.Fade(this, Opacity, 0, 140); else if (wasRemoving) Motion.Set(this, OpacityProperty, 1d);
        wasRemoving = model.Removing;
        var parent = Ancestor<ListBoxItem>(this); if (parent != null) Selection(parent.IsSelected);
    }
    static Color Hover(Color c) => Color.FromRgb((byte)(c.R * .86 + 255 * .14), (byte)(c.G * .86 + 255 * .14), (byte)(c.B * .86 + 255 * .14));
    internal static void Mark(TextBlock block, string value, string query)
    {
        block.Inlines.Clear();
        if (query.Length == 0) { block.Text = value; return; }
        var matches = SearchMatches.Find(value, query);
        if (matches.Count == 0) { block.Text = value; return; }
        int start = 0;
        foreach (var match in matches)
        {
            if (match.Start > start) block.Inlines.Add(new Run(value[start..match.Start]));
            block.Inlines.Add(new Run(value.Substring(match.Start, match.Length)) { Background = Theme.Brush("#E8B931") });
            start = match.Start + match.Length;
        }
        if (start < value.Length) block.Inlines.Add(new Run(value[start..]));
    }
    public static T? Ancestor<T>(DependencyObject node) where T : DependencyObject
    {
        while (node != null) { if (node is T found) return found; node = VisualTreeHelper.GetParent(node); } return null;
    }
    public static T? Descendant<T>(DependencyObject node) where T : DependencyObject
    {
        if (node is T found) return found;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) { var value = Descendant<T>(VisualTreeHelper.GetChild(node, i)); if (value != null) return value; }
        return null;
    }
}

public sealed class MainWindow : ChromeWindow
{
    public MainViewModel Model { get; }
    public ListBox Notes { get; } = new() { BorderThickness = new Thickness(0), Background = Brushes.Transparent, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    public TextBox Search { get; } = new() { FontSize = 13, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalContentAlignment = VerticalAlignment.Center };
    public TextBlock Status { get; } = Theme.Text("", 11);
    readonly TextBlock section = Theme.Text("", 11), empty = Theme.Text("", 13);
    readonly Button firstNote = new() { Margin = new Thickness(0, 14, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly StackPanel emptyPanel = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly Button sync, notices;
    readonly Border dot = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 8, 0) };
    readonly RotateTransform rotation = new();
    readonly TextBlock watermark = Theme.Text("搜索标题或内容", 13);
    readonly TextBlock shortcut = Theme.Text("Ctrl+F", 11);
    readonly Border searchFrame = new() { Height = 32, CornerRadius = new CornerRadius(6), Background = Brushes.White, BorderThickness = new Thickness(1), BorderBrush = Theme.Brush("#DDDED5") };
    readonly Button clearSearch;
    public RadioButton AllFilter { get; } = new() { Content = "全部" };
    public RadioButton PinnedFilter { get; } = new() { Content = "置顶" };
    DateTimeOffset? lastSync;
    public MainWindow(MainViewModel model)
    {
        Model = model; Width = 460; Height = 710; MinWidth = 360; MinHeight = 360; Title = "SongNote · 我的便签";
        Heading.Children.Add(Theme.Text("我的便签", 13, true));
        // The primary action reads as a button, not as another window glyph.
        var add = new Button { Style = Theme.Style("PrimaryButton"), Height = 26, ToolTip = "新建便签（Ctrl+N）", VerticalAlignment = VerticalAlignment.Center };
        var addContent = new StackPanel { Orientation = Orientation.Horizontal };
        addContent.Children.Add(Theme.Glyph("\uE710", 11, Brushes.White)); addContent.Children.Add(new TextBlock { Text = "新建", Margin = new Thickness(5, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        add.Content = addContent; add.Click += (_, _) => AppController.Current.NewNote();
        AutomationProperties.SetName(add, "新建便签"); WindowChrome.SetIsHitTestVisibleInChrome(add, true); Tools.Children.Add(add);
        var grid = new Grid { Margin = new Thickness(16, 4, 16, 8) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(42) }); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(34) });
        var searchRow = new Grid();
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); searchRow.ColumnDefinitions.Add(new ColumnDefinition()); searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var lens = Theme.Glyph("\uE721", 13, Theme.Muted); lens.Margin = new Thickness(10, 0, 8, 0); searchRow.Children.Add(lens);
        Grid.SetColumn(Search, 1); searchRow.Children.Add(Search); Search.ToolTip = "搜索标题或正文（Ctrl+F）"; AutomationProperties.SetName(Search, "搜索便签");
        Grid.SetColumn(watermark, 1); watermark.Margin = new Thickness(2, 0, 0, 0); watermark.IsHitTestVisible = false; searchRow.Children.Add(watermark);
        clearSearch = Theme.Icon("\uE711", "清除搜索（Esc）", () => { Search.Clear(); Search.Focus(); }, 26); clearSearch.Height = 26; clearSearch.FontSize = 10; clearSearch.Visibility = Visibility.Collapsed;
        shortcut.Margin = new Thickness(0, 0, 10, 0); shortcut.IsHitTestVisible = false;
        var trailing = new Grid { Margin = new Thickness(0, 0, 3, 0) }; trailing.Children.Add(shortcut); trailing.Children.Add(clearSearch); Grid.SetColumn(trailing, 2); searchRow.Children.Add(trailing);
        searchFrame.Child = searchRow; grid.Children.Add(searchFrame);
        searchFrame.MouseLeftButtonDown += (_, _) => Search.Focus();
        Search.GotKeyboardFocus += (_, _) => { searchFrame.BorderBrush = new SolidColorBrush(Theme.Ink); UpdateSearchChrome(); };
        Search.LostKeyboardFocus += (_, _) => { searchFrame.BorderBrush = Theme.Brush("#DDDED5"); UpdateSearchChrome(); };
        Search.TextChanged += (_, _) => { UpdateSearchChrome(); Model.Query = Search.Text; AppController.Current.Refresh(true); };
        Search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Down && Notes.Items.Count > 0) { SelectIndex(0); e.Handled = true; }
            else if (e.Key == Key.Escape && Search.Text.Length > 0) { Search.Clear(); e.Handled = true; }
        };
        var filters = new DockPanel { VerticalAlignment = VerticalAlignment.Center };
        var segments = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var option in new[] { AllFilter, PinnedFilter }) { option.Style = Theme.Style("SegmentButton"); option.GroupName = "filter-" + GetHashCode(); segments.Children.Add(option); }
        AllFilter.IsChecked = true; AutomationProperties.SetName(AllFilter, "显示全部便签"); AutomationProperties.SetName(PinnedFilter, "只显示置顶便签");
        AllFilter.Checked += (_, _) => { if (Model.PinnedOnly) { Model.PinnedOnly = false; AppController.Current.Refresh(true); } };
        PinnedFilter.Checked += (_, _) => { if (!Model.PinnedOnly) { Model.PinnedOnly = true; AppController.Current.Refresh(true); } };
        var track = new Border { Child = segments, Background = Theme.Brush("#ECEBE4"), CornerRadius = new CornerRadius(7), Padding = new Thickness(2), HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(track, Dock.Right); filters.Children.Add(track); section.FontSize = 12; filters.Children.Add(section);
        Grid.SetRow(filters, 1); grid.Children.Add(filters);
        Notes.ItemsSource = model.Items; ScrollViewer.SetHorizontalScrollBarVisibility(Notes, ScrollBarVisibility.Disabled); ScrollViewer.SetVerticalScrollBarVisibility(Notes, ScrollBarVisibility.Auto); ScrollViewer.SetCanContentScroll(Notes, false);
        var panel = new FrameworkElementFactory(typeof(ResponsiveNotesPanel)); Notes.ItemsPanel = new ItemsPanelTemplate(panel);
        var card = new FrameworkElementFactory(typeof(NoteCard)); Notes.ItemTemplate = new DataTemplate { VisualTree = card };
        var container = new Style(typeof(ListBoxItem)); container.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0))); container.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0))); container.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter)); var itemTemplate = new ControlTemplate(typeof(ListBoxItem)) { VisualTree = presenter }; container.Setters.Add(new Setter(Control.TemplateProperty, itemTemplate)); Notes.ItemContainerStyle = container;
        Notes.PreviewKeyDown += ListKeys; Grid.SetRow(Notes, 2); grid.Children.Add(Notes);
        Notes.SelectionChanged += (_, _) =>
        {
            for (int i = 0; i < Notes.Items.Count; i++)
                if (Notes.ItemContainerGenerator.ContainerFromIndex(i) is ListBoxItem item)
                    NoteCard.Descendant<NoteCard>(item)?.UpdateSelection(item.IsSelected);
        };
        empty.TextAlignment = TextAlignment.Center; empty.HorizontalAlignment = HorizontalAlignment.Center; empty.LineHeight = 21;
        var emptyIcon = Theme.Glyph("\uE70B", 30, Theme.Brush("#9A9F96")); emptyIcon.Margin = new Thickness(0, 0, 0, 12);
        firstNote.Style = Theme.Style("PrimaryButton"); firstNote.Content = "新建便签";
        firstNote.Click += (_, _) => AppController.Current.NewNote(); emptyPanel.Children.Add(emptyIcon); emptyPanel.Children.Add(empty); emptyPanel.Children.Add(firstNote); Grid.SetRow(emptyPanel, 2); grid.Children.Add(emptyPanel);
        sync = Theme.Icon("\uE895", "立即同步（Ctrl+R）", () => _ = AppController.Current.SyncNow()); sync.RenderTransform = rotation; sync.RenderTransformOrigin = new Point(.5, .5);
        notices = Theme.Icon("\uE7BA", "查看冲突提醒", () => AppController.Current.OpenNotice());
        var footer = new Grid { VerticalAlignment = VerticalAlignment.Bottom };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(dot); Grid.SetColumn(Status, 1); footer.Children.Add(Status); Grid.SetColumn(notices, 2); footer.Children.Add(notices); Grid.SetColumn(sync, 3); footer.Children.Add(sync);
        Grid.SetRow(footer, 3); grid.Children.Add(footer); Body.Content = grid;
        Closing += (_, e) => { if (AppController.Current.Quitting) return; e.Cancel = true; Hide(); AppController.Current.TrayHint(); AppController.Current.SavePlacement("list", this); };
    }
    public bool EmptyStateVisible => emptyPanel.Visibility == Visibility.Visible && firstNote.Visibility == Visibility.Visible;
    void UpdateSearchChrome()
    {
        bool typed = Search.Text.Length > 0;
        watermark.Visibility = typed ? Visibility.Collapsed : Visibility.Visible;
        clearSearch.Visibility = typed ? Visibility.Visible : Visibility.Collapsed;
        shortcut.Visibility = typed || Search.IsKeyboardFocusWithin ? Visibility.Collapsed : Visibility.Visible;
    }
    void SelectIndex(int index)
    {
        if (index < 0 || index >= Notes.Items.Count || ((NoteViewModel)Notes.Items[index]).Removing) return;
        Notes.SelectedIndex = index; Notes.ScrollIntoView(Notes.SelectedItem); Notes.UpdateLayout();
        (Notes.ItemContainerGenerator.ContainerFromIndex(index) as ListBoxItem)?.Focus();
    }
    void ListKeys(object sender, KeyEventArgs e)
    {
        int index = Notes.SelectedIndex; int columns = NoteCard.Descendant<ResponsiveNotesPanel>(Notes)?.Columns ?? 1;
        if (e.Key is Key.Enter or Key.Space)
        { if (Notes.SelectedItem is NoteViewModel vm && !vm.Removing) AppController.Current.Open(vm.Id); e.Handled = true; return; }
        int delta = e.Key switch { Key.Left => -1, Key.Right => 1, Key.Up => -columns, Key.Down => columns, _ => 0 };
        if (delta != 0) { SelectIndex(index < 0 ? 0 : index + delta); e.Handled = true; }
    }
    public void Refresh(LocalState state, SyncService syncService, bool saved, string? saveError)
    {
        section.Text = Model.Section; empty.Text = Model.Empty;
        bool vacant = !Model.Items.Any(i => !i.Removing);
        emptyPanel.Visibility = vacant ? Visibility.Visible : Visibility.Collapsed;
        firstNote.Visibility = vacant && Model.Query.Trim().Length == 0 && !Model.PinnedOnly ? Visibility.Visible : Visibility.Collapsed;
        AllFilter.IsChecked = !Model.PinnedOnly; PinnedFilter.IsChecked = Model.PinnedOnly;
        Status.Text = Model.Status; Status.ToolTip = saveError ?? Model.Status;
        Status.Foreground = !saved ? Brushes.Firebrick : syncService.Error == null ? Theme.Muted : Brushes.DarkOrange;
        dot.Background = !saved ? Brushes.Firebrick : syncService.Error == null ? Theme.Brush("#457A63") : Brushes.DarkOrange;
        notices.Visibility = state.Visible().Any(n => n.ConflictOf != null || state.DeleteConflictIds.Contains(n.Id)) ? Visibility.Visible : Visibility.Collapsed;
        sync.IsEnabled = !syncService.Syncing; Motion.Spin(rotation, syncService.Syncing && syncService.ShowProgress);
        if (lastSync != syncService.LastSyncAt && syncService.ShowProgress && saved) Motion.Fade(dot, .35, 1, 350); lastSync = syncService.LastSyncAt;
    }
}
