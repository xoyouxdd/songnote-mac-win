using System.Windows.Controls.Primitives;

namespace SongNote.Windows;

static class DeleteCloseChecks
{
    public static int Run()
    {
        int cases = 0;
        for (int i = 0; i < 2; i++)
        {
            var store = new LocalStore(new MemoryStateFile());
            using var controller = new AppController(store, null, preview: true);
            var note = store.CreateDraft(); controller.Open(note.Id);
            var window = controller.Editors[note.Id]; window.Opacity = 0; window.Show(); window.Editor.Focus();
            window.Editor.Text = "虚构便签：输入后删除 " + i;
            if (i == 1)
            {
                System.ComponentModel.CancelEventHandler cancel = (_, e) => e.Cancel = true;
                window.Closing += cancel; window.Close(); window.Closing -= cancel;
                if (!controller.Editors.ContainsKey(note.Id)) throw new InvalidOperationException("Cancelled close removed editor");
                cases++;
            }
            bool closingRefreshed = false;
            // Deterministically reproduce the synchronous refresh delivered while WPF closes.
            window.Closing += (_, _) =>
            {
                if (closingRefreshed) return;
                closingRefreshed = true; controller.Refresh(true);
            };
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
            timer.Tick += (_, _) =>
            {
                var dialog = Application.Current.Windows.OfType<NoteDialog>().FirstOrDefault();
                if (dialog == null) return;
                timer.Stop(); dialog.ActionButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            };
            timer.Start();
            try { controller.Delete(note.Id, window); Pump(); }
            finally { timer.Stop(); }
            if (!closingRefreshed || controller.Editors.ContainsKey(note.Id) || !store.Snapshot().Notes[note.Id].Deleted)
                throw new InvalidOperationException("New/type/confirm-delete did not close safely");
            controller.Refresh(true); Pump(); controller.Main.Close(); cases++;
        }
        return cases;
    }
    static void Pump()
    {
        var frame = new DispatcherFrame();
        Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }
}
