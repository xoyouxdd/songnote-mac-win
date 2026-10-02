namespace SongNote.Windows;

// Use our own WPF browser: system Shell dialogs can fail-fast in-process on
// this host. Directory enumeration is asynchronous and never loads Shell UI.
public sealed class AttachmentPicker
{
    readonly Func<bool, string?, Task<string[]?>> select;
    int busy;
    public bool IsOpen => Volatile.Read(ref busy) != 0;
    public AttachmentPicker(string? initialDirectory = null) : this((save, name) => AttachmentBrowser.Select(save, name, initialDirectory)) { }
    internal AttachmentPicker(Func<bool, string?, Task<string[]?>> select) { this.select = select; }
    public Task<string[]?> Open() => Run(false, null);
    public async Task<string?> Save(string name) => (await Run(true, name))?.FirstOrDefault();
    async Task<string[]?> Run(bool save, string? name)
    {
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return null;
        try
        {
            return await select(save, name);
        }
        finally { Volatile.Write(ref busy, 0); }
    }
}
