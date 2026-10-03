using System.ComponentModel;
using System.Windows.Automation;
using System.Windows.Shell;

namespace SongNote.Windows;

public static class Theme
{
    public static readonly string[] Colors = ["yellow", "green", "blue", "pink", "purple", "gray"];
    public static readonly string[] Names = ["黄色", "绿色", "蓝色", "粉色", "紫色", "灰色"];
    // Note paper is one step softer than the accent so a full window of colour stays calm.
    static readonly string[] Papers = ["#FFF8DC", "#E9F5E1", "#E6F0FB", "#FCE8EE", "#F1E8FC", "#F1F1EC"];
    static readonly string[] Accents = ["#E8B931", "#5BAE6E", "#4A90D9", "#E07597", "#9B7BD8", "#92928A"];
    public static Color Ink => (Color)ColorConverter.ConvertFromString("#303633");
    public static SolidColorBrush Brush(string hex) => new((Color)ColorConverter.ConvertFromString(hex));
    public static SolidColorBrush Paper(string key) => Brush(Papers[Math.Max(0, Array.IndexOf(Colors, key))]);
    public static SolidColorBrush Accent(string key) => Brush(Accents[Math.Max(0, Array.IndexOf(Colors, key))]);
    public static SolidColorBrush Muted => Brush("#596159");
    public static SolidColorBrush Faint => Brush("#8A8A82");
    public static SolidColorBrush Warning => Brush("#A15C00");
    public const string ListSurface = "#FAFAF8", Field = "#EFEEEA", Hairline = "#E3E2DC";
    public static readonly FontFamily TextFont = new("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI");
    public static void Install(Application app)
    {
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/Styles/ScrollBars.xaml") });
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/Styles/Controls.xaml") });
        var button = new Style(typeof(Button));
        button.Setters.Add(new Setter(Control.FontSizeProperty, 12d));
        button.Setters.Add(new Setter(Control.ForegroundProperty, new SolidColorBrush(Ink)));
        button.Setters.Add(new Setter(Control.BackgroundProperty, Brush("#FFFFFF")));
        button.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0)));
        button.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(6, 3, 6, 3)));
        button.Setters.Add(new Setter(Control.CursorProperty, Cursors.Hand));
        var border = new FrameworkElementFactory(typeof(Border)); border.Name = "surface";
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        content.SetValue(FrameworkElement.MarginProperty, new Thickness(4, 2, 4, 2)); border.AppendChild(content);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.78)); template.Triggers.Add(hover);
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.45)); template.Triggers.Add(disabled);
        button.Setters.Add(new Setter(Control.TemplateProperty, template)); app.Resources[typeof(Button)] = button;
    }
    public static readonly FontFamily Glyphs = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    public static Style Style(string key) => (Style)Application.Current.FindResource(key);
    public static Button Icon(string glyph, string label, Action action, double width = 28, string style = "ToolButton")
    {
        var button = new Button { Content = glyph, Width = width, Height = 28, Style = Style(style),
            ToolTip = label, FontFamily = Glyphs, FontSize = 14 };
        AutomationProperties.SetName(button, label); WindowChrome.SetIsHitTestVisibleInChrome(button, true);
        button.Click += (_, _) => action(); return button;
    }
    public static TextBlock Glyph(string glyph, double size = 14, Brush? color = null) => new()
    {
        Text = glyph, FontFamily = Glyphs, FontSize = size, Foreground = color ?? new SolidColorBrush(Ink),
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center
    };
    // Accent at reduced opacity: tinted borders and the selected pin, readable on every paper colour.
    public static SolidColorBrush Tint(string key, byte alpha)
    {
        var color = Accent(key).Color; return new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B));
    }
    public static TextBlock Text(string value, double size = 13, bool strong = false) => new()
    {
        Text = value, FontSize = size, Foreground = strong ? new SolidColorBrush(Ink) : Muted,
        FontWeight = strong ? FontWeights.SemiBold : FontWeights.Normal,
        TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center
    };
    // List section for an unpinned note: 今天 / 昨天 / 更早.
    public static string DayGroup(string value)
    {
        if (!DateTimeOffset.TryParse(value, out var date)) return "今天";
        var day = date.LocalDateTime.Date; return day == DateTime.Today ? "今天" : day == DateTime.Today.AddDays(-1) ? "昨天" : "更早";
    }
    // Compact time beside a list row; the section header already says which day.
    public static string ShortTime(string value)
    {
        if (!DateTimeOffset.TryParse(value, out var date)) return "刚刚";
        var local = date.LocalDateTime;
        return local.Date >= DateTime.Today.AddDays(-1) ? $"{local:HH:mm}" : local.Year == DateTime.Today.Year ? $"{local:M月d日}" : $"{local:yyyy/M/d}";
    }
    public static string Timestamp(string value)
    {
        if (!DateTimeOffset.TryParse(value, out var date)) return "刚刚";
        var local = date.LocalDateTime;
        return local.Date == DateTime.Today ? $"今天 {local:HH:mm}" : local.Date == DateTime.Today.AddDays(-1) ? $"昨天 {local:HH:mm}" : $"{local:M月d日 HH:mm}";
    }
    public static ContextMenu ColorsMenu(string id, string current, Action<string, string> select)
    {
        var menu = new ContextMenu { MinWidth = 236 };
        menu.Items.Add(new MenuItem { Header = "便签颜色", Style = Style("SectionMenuHeader"), IsEnabled = false });
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < Colors.Length; i++)
        {
            var key = Colors[i]; bool chosen = key == current;
            var dot = new Button { Width = 30, Height = 30, Margin = new Thickness(0, 0, 4, 0), Background = Accent(key), ToolTip = Names[i], Cursor = Cursors.Hand,
                FocusVisualStyle = Style("FocusRing"), Content = chosen ? Glyph("\uE73E", 12, new SolidColorBrush(Ink)) : null };
            var ring = new FrameworkElementFactory(typeof(Border)); ring.Name = "Ring";
            ring.SetValue(Border.CornerRadiusProperty, new CornerRadius(15)); ring.SetValue(Border.PaddingProperty, new Thickness(3));
            ring.SetValue(Border.BorderThicknessProperty, new Thickness(2)); ring.SetValue(Border.BorderBrushProperty, chosen ? new SolidColorBrush(Ink) : Brushes.Transparent);
            var fill = new FrameworkElementFactory(typeof(Border));
            fill.SetValue(Border.CornerRadiusProperty, new CornerRadius(11));
            fill.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
            var mark = new FrameworkElementFactory(typeof(ContentPresenter)); mark.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center); mark.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            fill.AppendChild(mark); ring.AppendChild(fill);
            var template = new ControlTemplate(typeof(Button)) { VisualTree = ring };
            if (!chosen)
            {
                var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
                hover.Setters.Add(new Setter(Border.BorderBrushProperty, new SolidColorBrush(Color.FromArgb(0x59, Ink.R, Ink.G, Ink.B)), "Ring")); template.Triggers.Add(hover);
            }
            dot.Template = template;
            AutomationProperties.SetName(dot, Names[i] + (chosen ? "，已选中" : ""));
            dot.Click += (_, _) => { select(id, key); menu.IsOpen = false; }; row.Children.Add(dot);
        }
        menu.Items.Add(new MenuItem { Header = row, Style = Style("PlainMenuRow"), StaysOpenOnClick = true, Focusable = false });
        var named = new MenuItem { Header = "按名称选择颜色" };
        for (int i = 0; i < Colors.Length; i++)
        {
            var key = Colors[i]; var item = new MenuItem { Header = Names[i], IsCheckable = true, IsChecked = key == current,
                Icon = new Border { Background = Accent(key), Width = 12, Height = 12, CornerRadius = new CornerRadius(6) } };
            item.Click += (_, _) => select(id, key); named.Items.Add(item);
        }
        menu.Items.Add(named); return menu;
    }
}

public static class Motion
{
    public static bool Suppress { get; set; }
    public static bool Enabled => !Suppress && SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;
    static readonly Dictionary<(DependencyObject, DependencyProperty), Action> clocks = [];
    public static int ActiveCount => clocks.Count;
    public static void Initialize() => SystemParameters.StaticPropertyChanged += PreferenceChanged;
    public static void Dispose() { SystemParameters.StaticPropertyChanged -= PreferenceChanged; Stop(); }
    static void PreferenceChanged(object? sender, PropertyChangedEventArgs e) { if (!Enabled) Stop(); }
    public static void Stop() { foreach (var action in clocks.Values.ToArray()) action(); clocks.Clear(); }
    public static void Set(UIElement target, DependencyProperty property, object value) => Begin(target, property, null, value);
    static void Begin(DependencyObject target, DependencyProperty property, AnimationTimeline? animation, object final)
    {
        var key = (target, property);
        if (clocks.Remove(key, out var previous)) previous();
        void SetAnimation(AnimationTimeline? value) { if (target is Animatable animatable) animatable.BeginAnimation(property, value); else ((UIElement)target).BeginAnimation(property, value); }
        SetAnimation(null); target.SetValue(property, final);
        if (!Enabled || animation == null) return;
        Action? done = null;
        done = () =>
        {
            if (clocks.TryGetValue(key, out var current) && current != done) return;
            SetAnimation(null); target.SetValue(property, final); clocks.Remove(key);
        };
        clocks[key] = done; animation.Completed += (_, _) => done(); SetAnimation(animation);
    }
    public static void Animate(Animatable target, DependencyProperty property, double from, double to, int milliseconds = 180)
    {
        var animation = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(milliseconds)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        Begin(target, property, animation, to);
    }
    public static void Fade(UIElement target, double from, double to, int milliseconds = 180)
    {
        Begin(target, UIElement.OpacityProperty, new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(milliseconds)), to);
    }
    public static void Color(SolidColorBrush brush, Color value)
    {
        var from = brush.Color;
        Begin(brush, SolidColorBrush.ColorProperty, from == value ? null : new ColorAnimation(from, value, TimeSpan.FromMilliseconds(180)), value);
    }
    public static void Spin(RotateTransform transform, bool active)
    {
        if (!active || !Enabled)
        {
            Begin(transform, RotateTransform.AngleProperty, null, 0d); return;
        }
        if (clocks.ContainsKey((transform, RotateTransform.AngleProperty))) return;
        Begin(transform, RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever }, 0d);
    }
}
