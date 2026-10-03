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
    protected SolidColorBrush Surface { get; } = Theme.Brush(Theme.ListSurface);
    readonly Border frame;
    readonly bool maximizable;
    public bool CanMaximize => maximizable;
    public int CaptionButtonCount { get; }
    public ChromeWindow(bool maximizable = true)
    {
        this.maximizable = maximizable;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize; Background = Surface;
        FontFamily = Theme.TextFont; Foreground = new SolidColorBrush(Theme.Ink);
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

// Rows grouped under small section headers (置顶 / 今天 / 昨天 / 更早); one column, two from 620 DIP.
// Headers are drawn by the panel so the list items stay one per note.
public sealed class ResponsiveNotesPanel : Panel
{
    public const double RowHeight = 56, RowGap = 2, ColumnGap = 8, HeaderHeight = 26, GroupGap = 6;
    public int Columns { get; private set; } = 1;
    Dictionary<UIElement, Rect> previous = [];
    readonly List<(string Title, Rect Bounds)> headers = [];
    public IReadOnlyList<(string Title, Rect Bounds)> Headers => headers;
    static string GroupOf(UIElement child) => (child as FrameworkElement)?.DataContext is NoteViewModel model ? model.Group : "";
    // Slots for live children in order, plus header rectangles and the total height.
    (List<Rect> Slots, List<(string, Rect)> Titles, double Height) Plan(double width)
    {
        double column = Math.Max(0, (width - (Columns - 1) * ColumnGap) / Columns);
        var slots = new List<Rect>(); var titles = new List<(string, Rect)>(); var seen = new HashSet<string>();
        double y = 0; string? current = null; int index = 0; bool any = false;
        foreach (UIElement child in InternalChildren)
        {
            if (!Live(child)) continue;
            var group = GroupOf(child);
            if (!any || group != current)
            {
                if (any) { y += Math.Ceiling(index / (double)Columns) * (RowHeight + RowGap) + GroupGap; index = 0; }
                if (group.Length > 0 && seen.Add(group)) { titles.Add((group, new Rect(12, y + 6, Math.Max(0, width - 24), 16))); y += HeaderHeight; }
                current = group; any = true;
            }
            slots.Add(new Rect((index % Columns) * (column + ColumnGap), y + (index / Columns) * (RowHeight + RowGap), column, RowHeight)); index++;
        }
        if (any) y += Math.Ceiling(index / (double)Columns) * (RowHeight + RowGap) - RowGap;
        return (slots, titles, Math.Max(0, y));
    }
    protected override Size MeasureOverride(Size available)
    {
        double width = double.IsInfinity(available.Width) ? Math.Max(360, ActualWidth) : available.Width;
        Columns = width >= 620 ? 2 : 1;
        double column = Math.Max(0, (width - (Columns - 1) * ColumnGap) / Columns);
        foreach (UIElement child in InternalChildren) child.Measure(new Size(column, RowHeight));
        return new Size(width, Plan(width).Height);
    }
    protected override Size ArrangeOverride(Size final)
    {
        var plan = Plan(final.Width); headers.Clear(); headers.AddRange(plan.Titles);
        double column = Math.Max(0, (final.Width - (Columns - 1) * ColumnGap) / Columns); var next = new Dictionary<UIElement, Rect>(); int slot = 0;
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            var child = InternalChildren[i];
            Rect rect;
            if (!Live(child))
            {
                if (!previous.TryGetValue(child, out rect)) { var offset = VisualTreeHelper.GetOffset(child); rect = new Rect(offset.X, offset.Y, column, RowHeight); }
            }
            else { rect = plan.Slots[slot]; slot++; }
            child.Arrange(rect); next[child] = rect;
            if (Motion.Enabled && previous.TryGetValue(child, out var old) && old.TopLeft != rect.TopLeft)
            {
                var transform = new TranslateTransform(); child.RenderTransform = transform;
                Motion.Animate(transform, TranslateTransform.XProperty, old.X - rect.X, 0);
                Motion.Animate(transform, TranslateTransform.YProperty, old.Y - rect.Y, 0);
            }
            else if (!previous.ContainsKey(child)) Motion.Fade(child, 0, 1);
        }
        previous = next; InvalidateVisual(); return final;
    }
    protected override void OnRender(DrawingContext context)
    {
        base.OnRender(context);
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var (title, bounds) in headers)
        {
            var text = new FormattedText(title, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface(Theme.TextFont, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), 11, Theme.Faint, dpi);
            context.DrawText(text, bounds.TopLeft);
        }
    }
    // Up/down in two columns stays in the same column, even across section headers.
    public int Neighbor(int index, int direction)
    {
        if (index < 0 || index >= InternalChildren.Count || !previous.TryGetValue(InternalChildren[index], out var from)) return -1;
        int best = -1; double distance = double.MaxValue;
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            var child = InternalChildren[i];
            if (i == index || !Live(child) || !previous.TryGetValue(child, out var rect) || Math.Abs(rect.X - from.X) > 1) continue;
            double delta = (rect.Y - from.Y) * direction;
            if (delta > 0 && delta < distance) { distance = delta; best = i; }
        }
        return best;
    }
    static bool Live(UIElement child) => NoteCard.Descendant<NoteCard>(child)?.Removing != true;
}

// One list row: colour dot, title with time on the right, one line of preview.
// Colour only marks the dot; selection is a white surface with an ink outline.
public sealed class NoteCard : UserControl
{
    readonly Border surface = new() { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0), ClipToBounds = true };
    readonly System.Windows.Shapes.Ellipse dot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock title = Theme.Text("", 14, true), preview = Theme.Text("", 13), meta = Theme.Text("", 11);
    readonly SolidColorBrush wash = new(Colors.Transparent);
    bool pressed, hovered, selected, wasRemoving;
    public bool Removing { get; private set; }
    NoteViewModel? model;
    public NoteCard()
    {
        Height = ResponsiveNotesPanel.RowHeight; surface.Background = wash;
        var grid = new Grid { Margin = new Thickness(12, 8, 12, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(20) }); grid.RowDefinitions.Add(new RowDefinition());
        meta.Foreground = Theme.Faint; meta.Margin = new Thickness(8, 0, 0, 0); meta.HorizontalAlignment = HorizontalAlignment.Right;
        grid.Children.Add(dot); Grid.SetColumn(title, 1); grid.Children.Add(title); Grid.SetColumn(meta, 2); grid.Children.Add(meta);
        Grid.SetRow(preview, 1); Grid.SetColumn(preview, 1); Grid.SetColumnSpan(preview, 2); preview.VerticalAlignment = VerticalAlignment.Top; preview.Margin = new Thickness(0, 1, 0, 0); grid.Children.Add(preview);
        surface.Child = grid; Content = surface;
        DataContextChanged += (_, _) => { if (model != null) model.PropertyChanged -= ModelChanged; model = DataContext as NoteViewModel; if (model != null) model.PropertyChanged += ModelChanged; Refresh(); };
        Unloaded += (_, _) => { if (model != null) model.PropertyChanged -= ModelChanged; };
        Loaded += (_, _) => { if (model != null) { model.PropertyChanged -= ModelChanged; model.PropertyChanged += ModelChanged; } Refresh(); };
        AddHandler(Selector.SelectedEvent, new RoutedEventHandler((_, _) => Selection(true)));
        AddHandler(Selector.UnselectedEvent, new RoutedEventHandler((_, _) => Selection(false)));
        MouseEnter += (_, _) => { hovered = true; Paint(); };
        MouseLeave += (_, _) => { pressed = false; hovered = false; Paint(); };
        PreviewMouseLeftButtonDown += (_, _) => { if (model?.Removing != false) return; pressed = true; var item = Ancestor<ListBoxItem>(this); if (item != null) { item.IsSelected = true; item.Focus(); } };
        MouseLeftButtonUp += (_, e) => { bool open = pressed && IsMouseOver && model?.Removing == false; pressed = false; if (open) AppController.Current.Open(model!.Id); e.Handled = true; };
        ContextMenuOpening += (_, _) => { if (model != null) ContextMenu = AppController.Current.NoteMenu(model.Id); };
        ContextMenu = new ContextMenu();
    }
    void ModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => Refresh();
    void Selection(bool value) { selected = value; Paint(); }
    void Paint()
    {
        surface.BorderThickness = new Thickness(selected ? 1.5 : 0); surface.BorderBrush = new SolidColorBrush(Theme.Ink);
        Motion.Color(wash, selected ? Colors.White : hovered ? Color.FromArgb(0x0D, Theme.Ink.R, Theme.Ink.G, Theme.Ink.B) : Colors.Transparent);
    }
    public void UpdateSelection(bool selected) => Selection(selected);
    public bool SelectionHighlighted => selected && surface.BorderThickness.Left > 0;
    void Refresh()
    {
        if (model == null) return;
        var query = AppController.Current == null ? "" : AppController.Current.Model.Query.Trim();
        Mark(title, model.Title, query);
        bool blank = model.Preview.Length == 0; Mark(preview, blank ? "没有更多内容" : model.Preview, blank ? "" : query);
        preview.Foreground = blank ? Theme.Faint : Theme.Muted;
        meta.Inlines.Clear(); meta.Foreground = model.Warning ? Theme.Warning : Theme.Faint;
        if (model.Flags.Length > 0) meta.Inlines.Add(new Run(string.Concat(model.Flags.Select(f => f + " · "))));
        if (model.Files > 0) { meta.Inlines.Add(new Run("\uE723") { FontFamily = Theme.Glyphs, FontSize = 10 }); meta.Inlines.Add(new Run(model.Files + "  ")); }
        meta.Inlines.Add(new Run(Theme.ShortTime(model.Note.UpdatedAt))); meta.ToolTip = model.Hint;
        dot.Fill = Theme.Accent(model.Note.Color); Paint();
        AutomationProperties.SetName(this, model.Title + "，" + model.Hint);
        IsHitTestVisible = !model.Removing;
        if (Removing != model.Removing) { Removing = model.Removing; Ancestor<ResponsiveNotesPanel>(this)?.InvalidateMeasure(); }
        else Ancestor<ResponsiveNotesPanel>(this)?.InvalidateMeasure();
        if (model.Removing) Motion.Fade(this, Opacity, 0, 140); else if (wasRemoving) Motion.Set(this, OpacityProperty, 1d);
        wasRemoving = model.Removing;
        var parent = Ancestor<ListBoxItem>(this); if (parent != null) Selection(parent.IsSelected);
    }
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
            block.Inlines.Add(new Run(value.Substring(match.Start, match.Length)) { Background = Theme.Brush("#73E8B931") });
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
    readonly TextBlock empty = Theme.Text("", 13);
    readonly Button firstNote = new() { Margin = new Thickness(0, 14, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly StackPanel emptyPanel = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly Button sync, notices;
    readonly Border dot = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 8, 0) };
    readonly RotateTransform rotation = new();
    readonly TextBlock watermark = Theme.Text("搜索", 13);
    readonly TextBlock shortcut = Theme.Text("Ctrl+F", 11);
    // Borderless search on a soft filled track; focus lifts it to white with a hairline.
    readonly Border searchFrame = new() { Height = 30, CornerRadius = new CornerRadius(7), Background = Theme.Brush(Theme.Field), BorderThickness = new Thickness(1), BorderBrush = Brushes.Transparent };
    readonly Button clearSearch;
    DateTimeOffset? lastSync;
    public MainWindow(MainViewModel model)
    {
        Model = model; Width = 460; Height = 710; MinWidth = 360; MinHeight = 360; Title = "SongNote · 便签";
        Heading.Children.Add(Theme.Text("便签", 13, true));
        var add = Theme.Icon("\uE710", "新建便签（Ctrl+N）", () => AppController.Current.NewNote()); add.Foreground = Theme.Muted; Tools.Children.Add(add);
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(6) }); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(34) });
        searchFrame.Margin = new Thickness(12, 0, 12, 0); Notes.Margin = new Thickness(8, 0, 8, 0);
        var searchRow = new Grid();
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); searchRow.ColumnDefinitions.Add(new ColumnDefinition()); searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var lens = Theme.Glyph("\uE721", 12, Theme.Faint); lens.Margin = new Thickness(10, 0, 7, 0); searchRow.Children.Add(lens);
        Grid.SetColumn(Search, 1); searchRow.Children.Add(Search); Search.ToolTip = "搜索标题或正文（Ctrl+F）"; AutomationProperties.SetName(Search, "搜索便签");
        watermark.Foreground = Theme.Faint; shortcut.Foreground = Theme.Faint;
        Grid.SetColumn(watermark, 1); watermark.Margin = new Thickness(2, 0, 0, 0); watermark.IsHitTestVisible = false; searchRow.Children.Add(watermark);
        clearSearch = Theme.Icon("\uE711", "清除搜索（Esc）", () => { Search.Clear(); Search.Focus(); }, 26); clearSearch.Height = 26; clearSearch.FontSize = 10; clearSearch.Visibility = Visibility.Collapsed;
        shortcut.Margin = new Thickness(0, 0, 10, 0); shortcut.IsHitTestVisible = false;
        var trailing = new Grid { Margin = new Thickness(0, 0, 3, 0) }; trailing.Children.Add(shortcut); trailing.Children.Add(clearSearch); Grid.SetColumn(trailing, 2); searchRow.Children.Add(trailing);
        searchFrame.Child = searchRow; grid.Children.Add(searchFrame);
        searchFrame.MouseLeftButtonDown += (_, _) => Search.Focus();
        Search.GotKeyboardFocus += (_, _) => { searchFrame.Background = Brushes.White; searchFrame.BorderBrush = Theme.Brush("#D0CFC8"); UpdateSearchChrome(); };
        Search.LostKeyboardFocus += (_, _) => { searchFrame.Background = Theme.Brush(Theme.Field); searchFrame.BorderBrush = Brushes.Transparent; UpdateSearchChrome(); };
        Search.TextChanged += (_, _) => { UpdateSearchChrome(); Model.Query = Search.Text; AppController.Current.Refresh(true); };
        Search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Down && Notes.Items.Count > 0) { SelectIndex(0); e.Handled = true; }
            else if (e.Key == Key.Escape && Search.Text.Length > 0) { Search.Clear(); e.Handled = true; }
        };
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
        sync.Foreground = Theme.Muted; notices.Foreground = Theme.Muted;
        var rule = new Border { Height = 1, Background = Theme.Brush(Theme.Hairline), VerticalAlignment = VerticalAlignment.Top }; Grid.SetRow(rule, 3); grid.Children.Add(rule);
        var footer = new Grid { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 1, 6, 0) };
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
        if (delta == 0) return;
        var panel = NoteCard.Descendant<ResponsiveNotesPanel>(Notes);
        if (index >= 0 && columns > 1 && Math.Abs(delta) == columns && panel != null) { int target = panel.Neighbor(index, Math.Sign(delta)); if (target >= 0) SelectIndex(target); }
        else SelectIndex(index < 0 ? 0 : index + delta);
        e.Handled = true;
    }
    public void Refresh(LocalState state, SyncService syncService, bool saved, string? saveError)
    {
        empty.Text = Model.Empty;
        bool vacant = !Model.Items.Any(i => !i.Removing);
        emptyPanel.Visibility = vacant ? Visibility.Visible : Visibility.Collapsed;
        firstNote.Visibility = vacant && Model.Query.Trim().Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Status.Text = Model.Status; Status.ToolTip = saveError ?? Model.Status;
        Status.Foreground = !saved ? Brushes.Firebrick : syncService.Error == null ? Theme.Muted : Brushes.DarkOrange;
        dot.Background = !saved ? Brushes.Firebrick : syncService.Error == null ? Theme.Brush("#457A63") : Brushes.DarkOrange;
        notices.Visibility = state.Visible().Any(n => n.ConflictOf != null || state.DeleteConflictIds.Contains(n.Id)) ? Visibility.Visible : Visibility.Collapsed;
        sync.IsEnabled = !syncService.Syncing; Motion.Spin(rotation, syncService.Syncing && syncService.ShowProgress);
        if (lastSync != syncService.LastSyncAt && syncService.ShowProgress && saved) Motion.Fade(dot, .35, 1, 350); lastSync = syncService.LastSyncAt;
    }
}
