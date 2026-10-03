using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Runs on the Windows-provided .NET Framework runtime, without WPF, notes,
// synchronization configuration or the main application's single-instance lock.
internal static class PickerHost
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 6) return 2;
        string action = args[0], nonce = args[1], directory = args[2], name = args[3];
        int parentId; long parentStart;
        if (!int.TryParse(args[4], out parentId) || !long.TryParse(args[5], out parentStart)) return 2;
        using (var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)))
        {
            try
            {
                if (action.StartsWith("test-", StringComparison.Ordinal))
                {
                    if (action == "test-crash") return 23;
                    if (action == "test-malformed") { output.Write("not-json"); return 0; }
                    if (action == "test-wait") { Thread.Sleep(30000); return 0; }
                    Write(output, action == "test-cancel" ? "canceled" : "selected", action,
                        action == "test-nonce" ? "wrong" : nonce,
                        action == "test-cancel" ? new string[0] : new[] { Path.Combine(directory, "虚构文件.txt") }, null);
                    return 0;
                }
                bool smoke = action.StartsWith("smoke-", StringComparison.Ordinal);
                bool save = action == "save" || action == "smoke-save";
                if (action != "open" && action != "save" && action != "smoke-open" && action != "smoke-save" && action != "smoke-cancel") return 2;
                using (var watch = new System.Threading.Timer(delegate
                {
                    try
                    {
                        using (var parent = Process.GetProcessById(parentId))
                            if (parent.StartTime.ToUniversalTime().Ticks != parentStart) Environment.Exit(0);
                    }
                    catch { Environment.Exit(0); }
                }, null, 500, 500))
                {
                    Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                    using (var owner = new Form())
                    using (FileDialog dialog = save ? (FileDialog)new SaveFileDialog() : new OpenFileDialog())
                    {
                        owner.Text = save ? "附件另存为" : "添加便签附件";
                        owner.ShowInTaskbar = true; owner.StartPosition = FormStartPosition.CenterScreen;
                        owner.Size = new Size(380, 260); owner.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                        dialog.Title = save ? "附件另存为" : "添加便签附件（单文件最多 20 MiB）";
                        dialog.AutoUpgradeEnabled = true; dialog.RestoreDirectory = true;
                        dialog.InitialDirectory = directory; dialog.Filter = "所有文件 (*.*)|*.*";
                        if (dialog is OpenFileDialog) { ((OpenFileDialog)dialog).Multiselect = true; dialog.CheckFileExists = true; }
                        else { dialog.FileName = name; ((SaveFileDialog)dialog).OverwritePrompt = true; }
                        if (smoke) dialog.FileName = Path.Combine(directory, save ? "系统选择框另存测试.txt" : "虚构文件.txt");
                        using (var automation = new System.Windows.Forms.Timer())
                        {
                            int attempts = 0;
                            automation.Interval = 250;
                            automation.Tick += delegate
                            {
                                if (!smoke) return;
                                IntPtr window = GetLastActivePopup(owner.Handle);
                                var title = new StringBuilder(256); GetWindowText(window, title, title.Capacity);
                                if (window != owner.Handle && title.ToString() == dialog.Title)
                                {
                                    int command = action == "smoke-cancel" ? 2 : 1;
                                    IntPtr button = GetDlgItem(window, command);
                                    if (button != IntPtr.Zero && IsWindowEnabled(button)) { PostMessage(window, 0x0111, new IntPtr(command), IntPtr.Zero); return; }
                                }
                                if (++attempts > 80) Environment.Exit(24);
                            };
                            owner.Show(); if (smoke) automation.Start();
                            var result = dialog.ShowDialog(owner); automation.Stop();
                            Write(output, result == DialogResult.OK ? "selected" : "canceled", action, nonce,
                                result == DialogResult.OK ? dialog.FileNames : new string[0], null);
                        }
                    }
                }
                return 0;
            }
            catch
            {
                Write(output, "error", action, nonce, new string[0], "系统文件选择框未能完成，请重试。");
                return 1;
            }
        }
    }
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr owner);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder title, int size);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    private static void Write(TextWriter output, string status, string action, string nonce, string[] paths, string error)
    {
        output.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object>
        { { "schema", 1 }, { "status", status }, { "action", action }, { "nonce", nonce }, { "paths", paths }, { "error", error } }));
        output.Flush();
    }
}
