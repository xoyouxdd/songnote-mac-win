using System.ComponentModel;
using System.Windows.Automation;
using System.Windows.Shell;

namespace SongNote.Windows;

public static class Theme
{
    public static readonly string[] Colors = ["yellow", "green", "blue", "pink", "purple", "gray"];
    public static readonly string[] Names = ["黄色", "绿色", "蓝色", "粉色", "紫色", "灰色"];
    static readonly string[] Papers = ["#FFF5C9", "#E0F0D6", "#DBEBFA", "#FAE0E8", "#EDE0FA", "#EDEDE8"];
    static readonly string[] Accents = ["#E8B931", "#5BAE6E", "#4A90D9", "#E07597", "#9B7BD8", "#92928A"];
    public static Color Ink => (Color)ColorConverter.ConvertFromString("#303633");
    public static SolidColorBrush Brush(string hex) => new((Color)ColorConverter.ConvertFromString(hex));
    public static SolidColorBrush Paper(string key) => Brush(Papers[Math.Max(0, Array.IndexOf(Colors, key))]);
    public static SolidColorBrush Accent(string key) => Brush(Accents[Math.Max(0, Array.IndexOf(Colors, key))]);
    public static SolidColorBrush Muted => Brush("#596159");
    public static void Install(Application app)
    {
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/Styles/ScrollBars.xaml") });
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
    public static Button Icon(string glyph, string label, Action action, double width = 28)
    {
        var button = new Button { Content = glyph, Width = width, Height = 28, Background = Brushes.Transparent,
            ToolTip = label, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 14 };
        AutomationProperties.SetName(button, label); WindowChrome.SetIsHitTestVisibleInChrome(button, true);
        button.Click += (_, _) => action(); return button;
    }
    public static TextBlock Text(string value, double size = 13, bool strong = false) => new()
    {
        Text = value, FontSize = size, Foreground = strong ? new SolidColorBrush(Ink) : Muted,
        FontWeight = strong ? FontWeights.SemiBold : FontWeights.Normal,
        TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center
    };
    public static System.Windows.Shapes.Path PinIcon(bool filled) => new()
    {
        Data = Geometry.Parse("M5,2 L11,2 L11,5 L13,8 L13,10 L9,10 L9,16 L8,18 L7,16 L7,10 L3,10 L3,8 L5,5 Z"),
        Width = 14, Height = 16, Stretch = Stretch.Uniform, StrokeThickness = 1.2,
        StrokeLineJoin = PenLineJoin.Round, Stroke = filled ? Brushes.White : new SolidColorBrush(Ink),
        Fill = filled ? Brushes.White : Brushes.Transparent
    };
    public static string Timestamp(string value)
    {
        if (!DateTimeOffset.TryParse(value, out var date)) return "刚刚";
        var local = date.LocalDateTime;
        return local.Date == DateTime.Today ? $"今天 {local:HH:mm}" : local.Date == DateTime.Today.AddDays(-1) ? $"昨天 {local:HH:mm}" : $"{local:M月d日 HH:mm}";
    }
    public static ContextMenu ColorsMenu(string id, string current, Action<string, string> select)
    {
        var menu = new ContextMenu();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6, 2, 6, 4) };
        for (int i = 0; i < Colors.Length; i++)
        {
            var key = Colors[i];
            var dot = new Button { Width = 28, Height = 28, Margin = new Thickness(2), Background = Accent(key), Content = key == current ? "✓" : "", ToolTip = Names[i] };
            var circle = new FrameworkElementFactory(typeof(Border)); circle.SetValue(Border.CornerRadiusProperty, new CornerRadius(14));
            circle.SetValue(Border.BorderBrushProperty, new SolidColorBrush(Ink)); circle.SetValue(Border.BorderThicknessProperty, new Thickness(key == current ? 2 : 0));
            circle.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
            var mark = new FrameworkElementFactory(typeof(ContentPresenter)); mark.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center); mark.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center); circle.AppendChild(mark);
            dot.Template = new ControlTemplate(typeof(Button)) { VisualTree = circle };
            AutomationProperties.SetName(dot, Names[i] + (key == current ? "，已选中" : ""));
            dot.Click += (_, _) => { select(id, key); menu.IsOpen = false; }; row.Children.Add(dot);
        }
        menu.Items.Add(new MenuItem { Header = row, StaysOpenOnClick = true });
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
