# py-crystal — write Python extension modules in Crystal

**py-crystal** is a framework for writing Python extension modules in [Crystal](https://crystal-lang.org/): statically compiled, GC-managed, and expressive — with the ergonomics of [PyO3](https://github.com/PyO3/pyo3) for Rust and [nimpy](https://github.com/yglukhov/nimpy) for Nim. Crystal exceptions become typed Python exceptions, ownership across the two heaps is handled automatically, and the whole C-API plumbing layer is generated at compile time from a small DSL, in either an annotation style or a block style.

A taste — a word counter that Python can iterate, size, compare, and add:

```crystal
require "pycr"

Pycr.pyclass WordCounter, "demo.WordCounter" do
  pynew def initialize
    @words = [] of String
  end

  pymethod def add(word : String) : Int32
    @words << word
    @words.size
  end

  pyiter def each : Iterator(String)   # for w in wc
    @words.each
  end

  pylen def size : Int32               # len(wc)
    @words.size
  end

  pyadd def plus(other : WordCounter) : WordCounter
    merged = WordCounter.new
    (@words + other.@words).each { |w| merged.add(w) }
    merged
  end
end
```

```python
from demo import WordCounter

a, b = WordCounter(), WordCounter()
a.add("crystal"); a.add("python")
b.add("static")

assert len(a) == 2
assert [w for w in a] == ["crystal", "python"]
assert (a + b).size == 3
assert a > b                       # rich comparison on word count

class Loud(WordCounter):           # Python subclassing, super() included
    def add(self, word):
        return super().add(word.upper())
```

Everything is generated at compile time from those signatures: argument conversion with `TypeError` on mismatch, `IndexError` mapped to Python's `IndexError`, iterators that survive GC cycles mid-stream. And the hard problems of hosting a second runtime inside CPython are solved and tested — foreign Python threads get full access to Crystal's fiber scheduler through a custom execution context with the GIL released, Boehm's collector coexists with CPython's through a serialized collection policy, and ownership across the two heaps is handled by a pin registry plus owned references. The whole thing passes a stress gauntlet and ships as one binary validated against CPython 3.11 through 3.14.

It's fast, with a real consumer to prove it: `examples/tartrazine` wraps the tartrazine highlighter in ~150 lines of DSL and benchmarks **11–12× faster than Pygments** on real files (0.8 ms vs 9.1 ms at 300 lines) with `--release`, and ~0.1 ms of per-call overhead. The project is MIT-licensed at **[github.com/ralsina/py-cr](https://github.com/ralsina/py-cr)** — a self-contained wheel (Linux x86_64, CPython 3.11–3.14) is on the [v0.1.0 release](https://github.com/ralsina/py-cr/releases/tag/v0.1.0), installable with `pip install <that wheel URL>`, with CI building and smoke-testing a fresh wheel on every push.
