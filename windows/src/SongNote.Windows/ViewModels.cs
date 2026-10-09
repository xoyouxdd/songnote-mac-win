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
    // Section header this row sits under; kept while the user is typing so rows do not jump between sections.
    public string Group { get; set; } = "";
    public string[] Flags
    {
        get
        {
            var flags = new List<string>();
            if (DeleteConflict) flags.Add("删除未执行");
            if (Note.ConflictOf != null) flags.Add("冲突副本");
            if (Pending) flags.Add("待同步");
            return flags.ToArray();
        }
    }
    public bool Warning => DeleteConflict || Note.ConflictOf != null;
    public int Files => Note.Attachments?.Length ?? 0;
    public string Hint
    {
        get
        {
            var parts = new List<string>(Flags);
            if (Files > 0) parts.Add($"附件 {Files} 个");
            parts.Add(Theme.Timestamp(Note.UpdatedAt));
            if (Note.Pinned) parts.Add("已置顶");
            return string.Join(" · ", parts);
        }
    }
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
    public string Status { get; private set; } = "";
    public string Empty => Query.Length > 0 ? "没有找到匹配的便签\n换个关键词试试" : "还没有便签\n随时按 Ctrl+N 新建一条";
    public void Refresh(LocalState state, string status, bool editing)
    {
        Status = status; Notify(nameof(Status));
        var next = state.Visible().Where(n => Query.Trim().Length == 0 || n.Text.Contains(Query.Trim(), StringComparison.CurrentCultureIgnoreCase)).ToList();
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
            var group = note.Pinned ? "已固定" : Theme.DayGroup(note.UpdatedAt);
            if (!editing || item.Group.Length == 0) item.Group = group;
            item.Update(note, state.Pending.ContainsKey(note.Id) || state.FrozenBatch.Any(c => c.NoteId == note.Id), state.DeleteConflictIds.Contains(note.Id));
            var current = Items.IndexOf(item); if (current != index) Items.Move(current, index);
        }
        Notify(nameof(Empty));
    }
    async void RemoveLater(NoteViewModel item)
    {
        if (Motion.Enabled) await Task.Delay(140);
        if (item.Removing) Items.Remove(item);
    }
}
