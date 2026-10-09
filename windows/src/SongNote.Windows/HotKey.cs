using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace SongNote.Windows;

// System-wide Ctrl+Alt+N for a new note from any app. A combination taken by another app is skipped.
public sealed class HotKey : IDisposable
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(nint hwnd, int id);
    const int Id = 0x534E, WmHotKey = 0x0312;
    const uint Alt = 0x1, Control = 0x2, NoRepeat = 0x4000;
    readonly HwndSource source;
    readonly Action action;
    HotKey(HwndSource source, Action action) { this.source = source; this.action = action; source.AddHook(Hook); }
    public static HotKey? Register(Window window, Action action)
    {
        var handle = new WindowInteropHelper(window).EnsureHandle();
        if (HwndSource.FromHwnd(handle) is not { } source) return null;
        if (!RegisterHotKey(handle, Id, Control | Alt | NoRepeat, (uint)KeyInterop.VirtualKeyFromKey(Key.N))) return null;
        return new HotKey(source, action);
    }
    nint Hook(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == WmHotKey && wParam == Id) { handled = true; action(); }
        return 0;
    }
    public void Dispose() { UnregisterHotKey(source.Handle, Id); source.RemoveHook(Hook); }
}
