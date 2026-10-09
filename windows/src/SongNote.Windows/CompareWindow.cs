using System.Windows.Automation;

namespace SongNote.Windows;

// Side-by-side view of a conflict copy and its original, with one-click resolution.
// The discarded version goes to 最近删除, so every choice can be undone for 7 days.
public sealed class CompareWindow : ChromeWindow
{
    public TextBox OriginalText { get; }
    public TextBox CopyText { get; }
    public CompareWindow(AppController controller, Note copy, Note original) : base(maximizable: false)
    {
        Title = "对比冲突内容"; Width = 680; Height = 440; MinWidth = 480; MinHeight = 300;
        Heading.Children.Add(Theme.Text("对比冲突内容", 13, true));
        var grid = new Grid { Margin = new Thickness(16, 2, 16, 16) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var hint = Theme.Text("另一台电脑同时改了这条便签。选择要保留的内容，另一份会移到「最近删除」，7 天内可恢复。", 12);
        hint.TextWrapping = TextWrapping.Wrap; hint.TextTrimming = TextTrimming.None; hint.Margin = new Thickness(0, 0, 0, 12); grid.Children.Add(hint);
        var columns = new Grid(); columns.ColumnDefinitions.Add(new ColumnDefinition()); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) }); columns.ColumnDefinitions.Add(new ColumnDefinition());
        OriginalText = Column(columns, 0, "原便签 · " + Theme.Timestamp(original.UpdatedAt), original);
        CopyText = Column(columns, 2, "冲突副本 · " + Theme.Timestamp(copy.UpdatedAt), copy);
        Grid.SetRow(columns, 1); grid.Children.Add(columns);
        var actions = new DockPanel { Margin = new Thickness(0, 14, 0, 0), LastChildFill = false };
        Button MakeButton(string label, string help, Action click, Dock side)
        {
            var button = new Button { Content = label, Height = 32, Padding = new Thickness(14, 0, 14, 0), Margin = new Thickness(side == Dock.Right ? 8 : 0, 0, 0, 0), Style = Theme.Style("SoftButton"), ToolTip = help };
            AutomationProperties.SetName(button, label); AutomationProperties.SetHelpText(button, help);
            button.Click += (_, _) => click(); DockPanel.SetDock(button, side); return button;
        }
        actions.Children.Add(MakeButton("打开原便签", "在便签窗口中打开原便签", () => controller.Open(original.Id), Dock.Left));
        var keepCopy = MakeButton("保留副本内容", "把副本内容写回原便签，然后删除副本", () => { controller.KeepConflictCopy(copy.Id); Close(); }, Dock.Right);
        var keepOriginal = MakeButton("保留原便签", "删除冲突副本，原便签保持不变", () => { controller.KeepOriginal(copy.Id); Close(); }, Dock.Right);
        var both = MakeButton("两份都保留", "关闭对比，两条便签都保留", Close, Dock.Right);
        // DockPanel stacks right-docked children from the edge inward.
        actions.Children.Add(keepCopy); actions.Children.Add(keepOriginal); actions.Children.Add(both);
        Grid.SetRow(actions, 2); grid.Children.Add(actions); Body.Content = grid;
    }
    static TextBox Column(Grid host, int column, string title, Note note)
    {
        var panel = new Grid(); panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); panel.RowDefinitions.Add(new RowDefinition());
        var label = Theme.Text(title, 12, true); label.Margin = new Thickness(0, 0, 0, 6); panel.Children.Add(label);
        var text = new TextBox { Text = note.Text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Padding = new Thickness(10), FontSize = 15, Foreground = new SolidColorBrush(Theme.Ink),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetName(text, title);
        var paper = new Border { CornerRadius = new CornerRadius(8), Background = Theme.Paper(note.Color), Child = text };
        Grid.SetRow(paper, 1); panel.Children.Add(paper); Grid.SetColumn(panel, column); host.Children.Add(panel);
        return text;
    }
}
