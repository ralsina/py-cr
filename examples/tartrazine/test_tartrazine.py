"""Tests and benchmarks for the tartrazine example module.

Run from examples/tartrazine after ./build.sh:

    python3 test_tartrazine.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import tartrazine  # noqa: E402


def main() -> None:
    print(tartrazine.version())
    assert "tartrazine" in tartrazine.version()

    themes = tartrazine.themes()
    print(f"{len(themes)} themes; 'github' present: {'github' in themes}")
    assert "github" in themes and "catppuccin-macchiato" in themes

    code = 'def greet(name):\n    print(f"hello {name}")\n'

    html = tartrazine.highlight(code, "python")
    assert "<span" in html and "greet" in html
    print("highlight(): spans and identifiers present")

    standalone = tartrazine.highlight(code, language="python", theme="github", standalone=True)
    assert "<!DOCTYPE" in standalone.upper() or "<html" in standalone
    numbered = tartrazine.highlight(code, language="python", line_numbers=True)
    assert "1" in numbered
    print("kwargs: language/theme/standalone/line_numbers all work")

    tokens = tartrazine.tokenize("puts 1 + 2", "crystal")
    assert ("LiteralNumber", "1") in tokens and ("Operator", "+") in tokens
    print(f"tokenize(): {len(tokens)} tokens, e.g. {tokens[0]}")

    lexer = tartrazine.Lexer("crystal")
    assert lexer.name == "crystal"
    assert repr(lexer) == "Lexer(crystal)"
    tokens = lexer.tokenize("puts 1")
    assert ("LiteralNumber", "1") in tokens
    print("Lexer class: constructor, attribute, __repr__, tokenize()")

    # ---- benchmarks -------------------------------------------------------
    source = open("test_tartrazine.py").read()
    print(f"\nbenchmark source: {len(source.splitlines())} lines, {len(source)} bytes")

    def bench(label, fn, count):
        fn()  # warmup
        started = time.perf_counter()
        for _ in range(count):
            fn()
        elapsed = time.perf_counter() - started
        per = elapsed / count * 1000
        print(f"  {label:30s} {per:8.3f} ms/call  ({count / elapsed:8.0f} calls/s)")
        return per

    tt_html = bench("tartrazine highlight()", lambda: tartrazine.highlight(source, "python"), 200)
    tt_tok = bench("tartrazine tokenize()", lambda: tartrazine.tokenize(source, "python"), 200)

    try:
        from pygments import highlight as pyg_highlight  # noqa: PLC0415
        from pygments.formatters.html import HtmlFormatter  # noqa: PLC0415
        from pygments.lexers.python import PythonLexer  # noqa: PLC0415
    except ImportError:
        print("  (pygments not installed, skipping comparison)")
        return

    pyg_html = bench(
        "pygments highlight()",
        lambda: pyg_highlight(source, PythonLexer(), HtmlFormatter()),
        50,
    )
    print(f"\nspeedup (html):   {pyg_html / tt_html:.1f}x")
    print(f"speedup (tokens): {pyg_html / tt_tok:.1f}x")
    print("ALL EXAMPLE TESTS PASSED")


if __name__ == "__main__":
    main()
