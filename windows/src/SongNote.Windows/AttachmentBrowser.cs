namespace SongNote.Windows;

public sealed record AttachmentFileEntry(string Path, string Name, bool Folder, long Size)
{
    public string Display => (Folder ? "📁 " : "📄 ") + Name + (Folder ? "" : "  ·  " + SizeLabel(Size));
    public static string SizeLabel(long size) => size < 1024 ? $"{size} B" : size < 1024 * 1024 ? $"{size / 1024d:0.#} KiB" : $"{size / (1024d * 1024):0.#} MiB";
}

// No shell COM objects, thumbnails, namespace providers or common-file dialogs.
// Only filesystem entries are read, on a pool thread, and shown as text.
public sealed class AttachmentBrowser : Window
{
    readonly bool save;
    readonly TextBox location = new() { MinWidth = 220, Padding = new Thickness(6, 5, 6, 5) };
    readonly TextBox filename = new() { Padding = new Thickness(6, 5, 6, 5) };
    readonly ListBox entries = new() { Margin = new Thickness(0, 8, 0, 8), DisplayMemberPath = nameof(AttachmentFileEntry.Display) };
    readonly TextBlock status = Theme.Text("", 11);
    readonly Button choose;
    CancellationTokenSource? loading;
    string directory;
    bool closed, reading, accepting, loadedDirectory;
    public string[]? SelectedPaths { get; private set; }
    AttachmentBrowser(bool save, string? name, string? initialDirectory)
    {
        this.save = save;
        var profile = Environment.GetEnvironmentVariable("USERPROFILE") ?? AppContext.BaseDirectory;
        directory = initialDirectory ?? Path.Combine(profile, "Downloads");
        Title = save ? "附件另存为" : "添加便签附件（单文件最多 20 MiB）";
        Width = 660; Height = 470; MinWidth = 440; MinHeight = 320; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Theme.Brush("#F7F7F4"); FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 13;
        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var path = new DockPanel();
        var go = Button("转到", async () => await Navigate(location.Text)); DockPanel.SetDock(go, Dock.Right); path.Children.Add(go);
        var up = Button("上一级", async () => await Navigate(System.IO.Directory.GetParent(directory)?.FullName ?? directory)); DockPanel.SetDock(up, Dock.Left); path.Children.Add(up);
        location.Text = directory; path.Children.Add(location); root.Children.Add(path);
        System.Windows.Automation.AutomationProperties.SetName(location, "文件夹或完整文件路径");
        location.KeyDown += async (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; await Navigate(location.Text); } };
        entries.SelectionMode = save ? SelectionMode.Single : SelectionMode.Extended;
        ScrollViewer.SetCanContentScroll(entries, true); VirtualizingPanel.SetIsVirtualizing(entries, true);
        VirtualizingPanel.SetVirtualizationMode(entries, VirtualizationMode.Recycling);
        System.Windows.Automation.AutomationProperties.SetName(entries, "文件列表");
        entries.MouseDoubleClick += async (_, e) =>
        {
            if (e.OriginalSource is not DependencyObject source || ItemsControl.ContainerFromElement(entries, source) is not ListBoxItem) return;
            if (entries.SelectedItem is not AttachmentFileEntry item) return;
            if (item.Folder) await Navigate(item.Path); else if (!save) await Accept(); else filename.Text = item.Name;
        };
        entries.KeyDown += async (_, e) =>
        {
            if (e.Key != Key.Enter) return; e.Handled = true;
            if (entries.SelectedItem is AttachmentFileEntry { Folder: true } folder) await Navigate(folder.Path); else await Accept();
        };
        entries.SelectionChanged += (_, _) => { if (save && entries.SelectedItem is AttachmentFileEntry { Folder: false } item) filename.Text = item.Name; };
        Grid.SetRow(entries, 1); root.Children.Add(entries);
        filename.Text = name ?? ""; filename.Margin = new Thickness(0, 0, 0, 8); filename.Visibility = save ? Visibility.Visible : Visibility.Collapsed;
        System.Windows.Automation.AutomationProperties.SetName(filename, "另存文件名"); Grid.SetRow(filename, 2); root.Children.Add(filename);
        var footer = new DockPanel(); status.TextWrapping = TextWrapping.Wrap; status.VerticalAlignment = VerticalAlignment.Center;
        var cancel = Button("取消", () => DialogResult = false); cancel.IsCancel = true; DockPanel.SetDock(cancel, Dock.Right); footer.Children.Add(cancel);
        choose = Button(save ? "保存" : "添加", async () => await Accept()); DockPanel.SetDock(choose, Dock.Right); footer.Children.Add(choose);
        footer.Children.Add(status); Grid.SetRow(footer, 3); root.Children.Add(footer); Content = root;
        Loaded += async (_, _) => await Navigate(directory);
        Closed += (_, _) => { closed = true; loading?.Cancel(); };
    }
    static Button Button(string text, Action action)
    {
        var button = new Button { Content = text, Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(4, 0, 0, 0) };
        button.Click += (_, _) => action(); return button;
    }
    public static async Task<string[]?> Select(bool save, string? name, string? initialDirectory)
    {
        // Defer dialog creation until the caller has yielded; WPF's modal
        // dispatcher keeps rendering and synchronization callbacks running.
        await Dispatcher.Yield(DispatcherPriority.Background);
        if (Application.Current.Dispatcher.HasShutdownStarted) return null;
        var browser = new AttachmentBrowser(save, name, initialDirectory);
        var owner = Application.Current.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive && w.IsVisible);
        if (owner != null) browser.Owner = owner;
        browser.ShowDialog(); return browser.SelectedPaths;
    }
    internal static Task<AttachmentFileEntry[]> ReadFolder(string path, CancellationToken cancellation = default) => Task.Run(() =>
    {
        var result = new List<AttachmentFileEntry>();
        foreach (var item in System.IO.Directory.EnumerateFileSystemEntries(path))
        {
            cancellation.ThrowIfCancellationRequested();
            try
            {
                var attributes = File.GetAttributes(item);
                if ((attributes & FileAttributes.Hidden) != 0) continue;
                bool folder = (attributes & FileAttributes.Directory) != 0;
                result.Add(new(item, Path.GetFileName(item), folder, folder ? 0 : new FileInfo(item).Length));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return result.OrderByDescending(x => x.Folder).ThenBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }, cancellation);
    async Task Navigate(string value)
    {
        if (closed || accepting) return;
        loading?.Cancel(); var operation = new CancellationTokenSource(); loading = operation;
        reading = true; choose.IsEnabled = false; status.Text = "正在读取文件夹…";
        try
        {
            var path = Path.GetFullPath(value.Trim().Trim('"'));
            bool isFile = await Task.Run(() => File.Exists(path), operation.Token);
            if (closed || operation.IsCancellationRequested) return;
            if (isFile)
            {
                if (!save) { SelectedPaths = [path]; DialogResult = true; return; }
                filename.Text = Path.GetFileName(path); path = Path.GetDirectoryName(path)!;
            }
            var values = await ReadFolder(path, operation.Token);
            if (closed || operation.IsCancellationRequested) return;
            directory = path; location.Text = path; entries.ItemsSource = values; loadedDirectory = true;
            status.Text = save ? "输入文件名后保存" : "可多选文件；也可粘贴完整文件路径";
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            if (!closed && !operation.IsCancellationRequested)
            { location.Text = directory; status.Text = "无法读取此位置，请换一个文件夹或粘贴文件路径。"; }
        }
        finally
        {
            if (ReferenceEquals(loading, operation)) { loading = null; if (!closed) { reading = false; choose.IsEnabled = loadedDirectory && !accepting; } }
            operation.Dispose();
        }
    }
    async Task Accept()
    {
        if (reading || accepting || closed || (save && !loadedDirectory)) return;
        if (!save)
        {
            var paths = entries.SelectedItems.OfType<AttachmentFileEntry>().Where(x => !x.Folder).Select(x => x.Path).ToArray();
            if (paths.Length == 0) { status.Text = "请选择文件，双击文件夹可进入。"; return; }
            SelectedPaths = paths; DialogResult = true; return;
        }
        var name = filename.Text.Trim();
        if (name.Length == 0 || name is "." or ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        { status.Text = "请输入有效的文件名。"; return; }
        var destination = Path.Combine(directory, name);
        accepting = true; choose.IsEnabled = false;
        try
        {
            bool exists = await Task.Run(() => File.Exists(destination)); if (closed) return;
            if (exists && MessageBox.Show(this, "覆盖已有文件？\n" + name, "附件另存为", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
            if (closed || Dispatcher.HasShutdownStarted) return; SelectedPaths = [destination]; DialogResult = true;
        }
        finally { accepting = false; if (!closed) choose.IsEnabled = loadedDirectory; }
    }
}
