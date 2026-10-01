"""Optional Windows syntax check. This does not type-check Swift or AppKit."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "build" / "validation-tools"))

try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    raise SystemExit(
        "Install in the project: python -m pip install --target build/validation-tools "
        "tree-sitter==0.26.0 tree-sitter-swift==0.7.3"
    )

parser = Parser(Language(tree_sitter_swift.language()))
failed = False
for path in sorted((ROOT / "macos").glob("*.swift")) + sorted((ROOT / "tests").glob("*.swift")):
    data = path.read_bytes()
    tree = parser.parse(data)
    stack = [tree.root_node]
    errors = []
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append((node.start_point, data[node.start_byte:node.end_byte].decode("utf-8", errors="replace")[:120]))
        stack.extend(node.children)
    label = path.relative_to(ROOT)
    if errors:
        failed = True
        for point, snippet in errors:
            print(f"SWIFT_SYNTAX_ERROR: {label}:{point.row + 1}:{point.column + 1}: {snippet}")
    else:
        print(f"SWIFT_SYNTAX_OK: {label}")
raise SystemExit(1 if failed else 0)
