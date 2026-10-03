namespace SongNote.Windows;

// The system dialog runs in a small, separate Windows-runtime process.
// Its native failures cannot terminate or block the WPF note application.
public sealed class AttachmentPicker : IDisposable
{
    readonly Func<bool, string?, Task<string[]?>> select;
    readonly SystemFilePicker? system;
    int busy;
    public bool IsOpen => Volatile.Read(ref busy) != 0;
    public AttachmentPicker(string? initialDirectory = null) { system = new(initialDirectory); select = system.Select; }
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
    public void Dispose() => system?.Dispose();
}
