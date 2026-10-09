using System.Windows.Automation;
using System.Windows.Shell;

namespace SongNote.Windows;

// Modal application prompts share the paper theme; file pickers remain native.
public sealed class NoteDialog : Window
{
    public Button ActionButton { get; }
    public Button DismissButton { get; }
    public NoteDialog(string title, string message, string? action = null)
    {
        Title = title; Width = 380; SizeToContent = SizeToContent.Height;
        MaxHeight = Math.Max(180, SystemParameters.WorkArea.Height - 40);
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = Theme.TextFont; Foreground = new SolidColorBrush(Theme.Ink);
        Background = Theme.Brush(Theme.ListSurface); UseLayoutRounding = true;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 40,
            ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0, 0, 0, 1), UseAeroCaptionButtons = false });
        SourceInitialized += (_, _) => NativeFrame.Apply(this, false);
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var heading = new Grid { Margin = new Thickness(20, 0, 8, 0) };
        heading.ColumnDefinitions.Add(new ColumnDefinition());
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        heading.Children.Add(Theme.Text(title, 13, true));
        var close = Theme.Icon("\uE8BB", "关闭提示", () => DialogResult = false, 28, "CloseButton");
        Grid.SetColumn(close, 1); heading.Children.Add(close); root.Children.Add(heading);
        var text = Theme.Text(message, 14);
        text.TextWrapping = TextWrapping.Wrap; text.TextTrimming = TextTrimming.None;
        text.VerticalAlignment = VerticalAlignment.Top; text.LineHeight = 23;
        var scroll = new ScrollViewer { Content = text, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Margin = new Thickness(20, 14, 20, 22) };
        Grid.SetRow(scroll, 1); root.Children.Add(scroll);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(20, 0, 20, 20) };
        DismissButton = new Button { Content = action == null ? "知道了" : "取消", MinWidth = 76, Height = 34,
            Style = Theme.Style("SoftButton"), IsCancel = true, IsDefault = action == null };
        AutomationProperties.SetName(DismissButton, (string)DismissButton.Content);
        DismissButton.Click += (_, _) => DialogResult = false; buttons.Children.Add(DismissButton);
        ActionButton = new Button { Content = action, MinWidth = 76, Height = 34, Margin = new Thickness(10, 0, 0, 0),
            Style = Theme.Style("SoftButton"), Background = Theme.Brush("#FCE8EE"), Foreground = Theme.Brush("#B42318"),
            Visibility = action == null ? Visibility.Collapsed : Visibility.Visible };
        AutomationProperties.SetName(ActionButton, action ?? "确认");
        ActionButton.Click += (_, _) => DialogResult = true; buttons.Children.Add(ActionButton);
        Grid.SetRow(buttons, 2); root.Children.Add(buttons);
        Content = new Border { Background = Background, BorderBrush = Theme.Brush(Theme.Hairline),
            BorderThickness = new Thickness(NativeFrame.RoundedByDwm ? 0 : 1), Child = root };
        Loaded += (_, _) => DismissButton.Focus();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { DialogResult = false; e.Handled = true; } };
    }
    static bool Show(Window? owner, string title, string message, string? action)
    {
        var dialog = new NoteDialog(title, message, action);
        // Startup failures and tray actions may have no visible owner.
        if (owner?.IsVisible == true) { dialog.Owner = owner; dialog.Topmost = owner.Topmost; }
        else dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        return dialog.ShowDialog() == true;
    }
    public static bool Confirm(Window owner, string title, string message, string action) => Show(owner, title, message, action);
    public static void Alert(Window? owner, string title, string message) => Show(owner, title, message, null);
}
