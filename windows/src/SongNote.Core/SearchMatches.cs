using System.Globalization;

namespace SongNote.Core;

public readonly record struct TextMatch(int Start, int Length);
public static class SearchMatches
{
    // Culture-aware matching can consume fewer/more UTF-16 units than the query.
    // Keep offsets into the original text so highlighting never rewrites content.
    public static IReadOnlyList<TextMatch> Find(string value, string query)
    {
        var matches = new List<TextMatch>();
        if (value.Length == 0 || query.Length == 0) return matches;
        var compare = CultureInfo.CurrentCulture.CompareInfo;
        int start = 0;
        while (start < value.Length)
        {
            int relative = compare.IndexOf(value.AsSpan(start), query.AsSpan(), CompareOptions.IgnoreCase, out int length);
            // An entirely ignorable query has a zero-width match; do not loop or
            // produce empty highlighted runs for it.
            if (relative < 0 || length == 0) break;
            int found = start + relative;
            matches.Add(new(found, length)); start = found + length;
        }
        return matches;
    }
}
