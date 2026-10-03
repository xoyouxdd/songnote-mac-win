namespace SongNote.Windows;

public static class AttachmentPickerChecks
{
    static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    static T Complete<T>(Task<T> task, int seconds = 3)
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) => frame.Continue = false;
        var dispatcher = Dispatcher.CurrentDispatcher;
        _ = task.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => frame.Continue = false)));
        timer.Start(); Dispatcher.PushFrame(frame); timer.Stop();
        Require(task.IsCompleted, "Picker task did not finish while the dispatcher was pumping");
        return task.GetAwaiter().GetResult();
    }
    static void Complete(Task task) => Complete(AsResult(task));
    static async Task<bool> AsResult(Task task) { await task; return true; }
    public static int Run()
    {
        int count = 0;
        bool heartbeat = false;
        {
            var completion = new TaskCompletionSource<string[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
            var picker = new AttachmentPicker((_, _) => completion.Task);
            var selected = picker.Open();
            Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => { heartbeat = picker.IsOpen; completion.SetResult(["虚构中文文件.txt"]); }));
            Require(Complete(selected)?.Single() == "虚构中文文件.txt" && heartbeat, "Picker blocked the editor dispatcher"); count++;
        }
        {
            int calls = 0;
            var completion = new TaskCompletionSource<string[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
            var picker = new AttachmentPicker((_, _) => { calls++; return completion.Task; });
            var first = picker.Open(); Require(Complete(picker.Open()) == null, "Second picker was not suppressed");
            completion.SetResult(null); Require(Complete(first) == null && calls == 1 && !picker.IsOpen, "Cancel did not release the shared picker gate"); count++;
        }
        {
            int calls = 0;
            var picker = new AttachmentPicker((save, name) => { if (++calls == 1) throw new IOException("Injected picker failure"); return Task.FromResult<string[]?>(save ? [name!] : null); });
            bool caught = false; try { Complete(picker.Open()); } catch (IOException) { caught = true; }
            Require(caught && !picker.IsOpen && Complete(picker.Save("虚构另存文件.txt")) == "虚构另存文件.txt", "Picker exception left the gate locked or was not propagated"); count++;
        }
        {
            var directory = Path.Combine(AppContext.BaseDirectory, "picker-check", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
            try
            {
                var source = Path.Combine(directory, "fixture.txt"); File.WriteAllText(source, "虚构附件");
                var note = Note.Blank() with { Text = "虚构便签", Revision = 1 };
                var state = new LocalState(); state.Notes[note.Id] = note;
                var store = new LocalStore(new MemoryStateFile { Data = state });
                var completion = new TaskCompletionSource<string[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
                var picker = new AttachmentPicker((_, _) => completion.Task);
                using var controller = new AppController(store, null, true, picker, directory); controller.Open(note.Id);
                var window = controller.Editors[note.Id]; var adding = controller.AddAttachment(note.Id, window);
                window.Close(); completion.SetResult([source]); Complete(adding);
                Require((store.Snapshot().Notes[note.Id].Attachments?.Length ?? 0) == 0 && store.Snapshot().Pending.Count == 0 && !Directory.Exists(Path.Combine(directory, "attachments")), "Closed note received a late attachment");
                controller.Main.Close(); count++;
            }
            finally { Directory.Delete(directory, true); }
        }
        {
            var directory = Path.Combine(AppContext.BaseDirectory, "picker-check", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
            try
            {
                var source = Path.Combine(directory, "虚构文件.txt"); File.WriteAllText(source, "虚构数据");
                using var system = new SystemFilePicker(directory);
                Require(Complete(system.Check("test-selected", directory))?.Single() == source, "Helper Unicode protocol did not round-trip"); count++;
                foreach (var fault in new[] { "test-crash", "test-malformed", "test-nonce" })
                {
                    bool refused = false;
                    try { Complete(system.Check(fault, directory)); } catch (Exception e) when (e is IOException or InvalidDataException) { refused = true; }
                    Require(refused && Complete(system.Check("test-selected", directory))?.Single() == source, "Helper failure killed or poisoned the parent client"); count++;
                }
                using (var cancel = new CancellationTokenSource(100))
                    Require(Complete(system.Check("test-wait", directory, cancel.Token)) == null, "Canceled helper did not terminate");
                count++;
                Require(Complete(system.Check("smoke-open", directory), 25)?.Single() == source, "Real system Open dialog did not select the Unicode fixture"); count++;
                Require(Complete(system.Check("smoke-cancel", directory), 25) == null, "Real system Open dialog did not cancel"); count++;
                var destination = Path.Combine(directory, "系统选择框另存测试.txt");
                Require(Complete(system.Check("smoke-save", directory), 25)?.Single() == destination, "Real system Save dialog did not return the fixture destination"); count++;
                using var http = new System.Net.Http.HttpClient(); var files = new AttachmentFiles(directory, null, http);
                var attachment = Complete(files.Import(source)); Complete(files.Download(attachment, destination));
                Require(File.ReadAllBytes(source).SequenceEqual(File.ReadAllBytes(destination)), "System picker round trip changed fixture bytes"); count++;
            }
            finally { Directory.Delete(directory, true); }
        }
        return count;
    }
}
