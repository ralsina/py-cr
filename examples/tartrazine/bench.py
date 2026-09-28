"""Benchmark: tartrazine (Crystal, release build) vs pygments.

Uses the timeit module's methodology: repeated batches, report the
BEST wall-clock per call (timeit's own recommendation, since it is the
least disturbed by other system activity). Lexers/formatters are
constructed per call for both sides, matching how each public API is
normally used.

    python3 bench.py
"""

import timeit

import os

# Realistic Python sources: copied stdlib files if present, else
# synthesized repetitions of a representative snippet.
def ensure_input(path, lines):
    if os.path.exists(path):
        return
    # prefer real stdlib sources when available
    import shutil
    import sysconfig
    stdlib = sysconfig.get_paths()["stdlib"]
    candidates = {
        "bench/small.py": ["argparse.py"],
        "bench/medium.py": ["argparse.py"],
        "bench/dataclasses.py": ["dataclasses.py"],
        "bench/large.py": ["argparse.py", "dataclasses.py", "random.py"],
    }
    files = candidates.get(path, [])
    if files and all(os.path.exists(os.path.join(stdlib, f)) for f in files):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        text = "".join(open(os.path.join(stdlib, f)).read() for f in files)
        # small/medium are truncations; large/dataclasses stay whole
        if lines <= 1000:
            text = "".join(text.splitlines(keepends=True)[:lines])
        with open(path, "w") as out:
            out.write(text)
        return
    base = (
        "import os\n"
        "class Sample:\n"
        '    """Representative class docstring."""\n'
        "    def __init__(self, name: str, values: list[int] | None = None):\n"
        "        self.name = name\n"
        "        self.values = values or []\n"
        "    def compute(self, factor: float = 1.0) -> float:\n"
        "        total = sum(v * factor for v in self.values)\n"
        "        return total / (len(self.values) or 1)\n"
        "def main() -> None:\n"
        "    sample = Sample('demo', [1, 2, 3])\n"
        "    print(f'{sample.compute(2.0):.2f}')\n"
        "if __name__ == '__main__':\n"
        "    main()\n"
    )
    repeats = max(1, lines // 16)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(base * repeats)


INPUTS = [
    ("small", "bench/small.py", 20),
    ("medium", "bench/medium.py", 300),
    ("dataclasses", "bench/dataclasses.py", 1813),
    ("large", "bench/large.py", 5689),
]
for _label, _path, _lines in INPUTS:
    ensure_input(_path, _lines)

TT = "tartrazine.highlight(src, 'python')"
PYG = "highlight(src, PythonLexer(), HtmlFormatter())"

TT_TOK = "tartrazine.tokenize(src, 'python')"

print(f"{'input':<14} {'lines':>6}  {'tartrazine':>12}  {'pygments':>12}  {'speedup':>8}")
print("-" * 60)

for label, path, lines in INPUTS:
    src = open(path).read()
    setup = (
        "import sys; sys.path.insert(0, '.'); import tartrazine\n"
        "from pygments import highlight\n"
        "from pygments.lexers.python import PythonLexer\n"
        "from pygments.formatters.html import HtmlFormatter\n"
        f"src = open({path!r}).read()\n"
    )

    def best(stmt, number):
        timer = timeit.Timer(stmt, setup)
        # calibrate: aim for >=0.2s per batch
        number, _ = timer.autorange()
        times = timer.repeat(repeat=5, number=number)
        return min(times) / number, number

    tt, tt_n = best(TT, 0)
    pyg, pyg_n = best(PYG, 0)
    print(
        f"{label:<14} {lines:>6}  {tt * 1000:>9.3f} ms  {pyg * 1000:>9.3f} ms  {pyg / tt:>7.1f}x"
    )

print()
print(f"{'tokenize (tokens, no HTML)':<32}")
for label, path, lines in INPUTS[1:]:
    src = open(path).read()
    setup = "import sys; sys.path.insert(0, '.'); import tartrazine\n" f"src = open({path!r}).read()\n"
    timer = timeit.Timer(TT_TOK, setup)
    number, _ = timer.autorange()
    times = timer.repeat(repeat=5, number=number)
    tt = min(times) / number
    print(f"{label:<14} {lines:>6}  {tt * 1000:>9.3f} ms  ({1 / tt:8.0f} calls/s)")
