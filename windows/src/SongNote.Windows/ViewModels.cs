using System.Collections.ObjectModel;
using System.ComponentModel;

namespace SongNote.Windows;

public abstract class ViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Notify(string name) => PropertyChanged?.Invoke(this, new(name));
}
public sealed class NoteViewModel : ViewModel
{
    public Note Note { get; private set; }
    public bool Pending { get; private set; }
    public bool DeleteConflict { get; private set; }
    public bool Removing { get; private set; }
    public string Id => Note.Id;
    public string Title => Note.Title;
    public string Preview => string.Join(" ", Note.DisplayLines.Skip(1));
    public string Hint => (DeleteConflict ? "删除未执行 · " : "") + (Note.ConflictOf != null ? "冲突副本 · " : Note.Pinned ? "置顶 · " : "") + Theme.Timestamp(Note.UpdatedAt) + (Pending ? " · 待同步" : "");
    public NoteViewModel(Note note) { Note = note; }
    public void Update(Note note, bool pending, bool conflict)
    {
        Note = note; Pending = pending; DeleteConflict = conflict; Removing = false;
        Notify(nameof(Note)); Notify(nameof(Title)); Notify(nameof(Preview)); Notify(nameof(Hint)); Notify(nameof(Removing));
    }
    public void BeginRemoval() { Removing = true; Notify(nameof(Removing)); }
}
public sealed class MainViewModel : ViewModel
{
    public ObservableCollection<NoteViewModel> Items { get; } = [];
    public string Query { get; set; } = "";
    public bool PinnedOnly { get; set; }
    public string Status { get; private set; } = "";
    public string Section => (PinnedOnly ? "置顶便签" : "全部便签") + " · " + Items.Count(i => !i.Removing);
    public string Empty => Query.Length > 0 ? "没有找到匹配的便签\n换个关键词试试" : PinnedOnly ? "还没有置顶便签\n右键便签或点窗口图钉" : "记下第一件小事\n点右上角 + 开始";
    public void Refresh(LocalState state, string status, bool editing)
    {
        Status = status; Notify(nameof(Status));
        var next = state.Visible().Where(n => (!PinnedOnly || n.Pinned) && (Query.Trim().Length == 0 || n.Text.Contains(Query.Trim(), StringComparison.CurrentCultureIgnoreCase))).ToList();
        if (editing)
        {
            var oldOrder = Items.Select((item, index) => (item.Id, index)).ToDictionary(p => p.Id, p => p.index);
            next = next.OrderBy(n => oldOrder.GetValueOrDefault(n.Id, int.MaxValue)).ToList();
        }
        var ids = next.Select(n => n.Id).ToHashSet();
        foreach (var old in Items.Where(i => !ids.Contains(i.Id) && !i.Removing).ToArray())
        {
            old.BeginRemoval(); RemoveLater(old);
        }
        for (int index = 0; index < next.Count; index++)
        {
            var note = next[index]; var item = Items.FirstOrDefault(i => i.Id == note.Id);
            if (item == null) { item = new(note); Items.Insert(Math.Min(index, Items.Count), item); }
            item.Update(note, state.Pending.ContainsKey(note.Id) || state.FrozenBatch.Any(c => c.NoteId == note.Id), state.DeleteConflictIds.Contains(note.Id));
            var current = Items.IndexOf(item); if (current != index) Items.Move(current, index);
        }
        Notify(nameof(Section)); Notify(nameof(Empty));
    }
    async void RemoveLater(NoteViewModel item)
    {
        if (Motion.Enabled) await Task.Delay(140);
        if (item.Removing) Items.Remove(item); Notify(nameof(Section));
    }
}
