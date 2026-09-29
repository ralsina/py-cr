# py-cr (temporary name)

A framework for writing Python extension modules in Crystal: compile
Crystal code into a CPython-importable `.so`, the way
[PyO3](https://github.com/PyO3/pyo3) does it for Rust and
[nimpy](https://github.com/yglukhov/nimpy) for Nim. The framework is
library-agnostic: any Crystal code can be exposed, and `src/demo.cr`
is just one example module used as the framework's test surface.

## Install

From the GitHub release (Linux x86_64):

- CPython 3.11-3.14: `pip install <regular wheel URL from the release>`
- Free-threaded CPython (3.13t/3.14t): `pip install <cp313t.cp314t wheel URL>`

The wheels bundle their own Boehm GC; no system Crystal or libgc
required.

## The annotation style

```crystal
require "./pycr"

@[Pycr::PyClass("mymodule.Greeter")]
class Greeter < Pycr::PyObject
  @[Pycr::PyNew]
  def initialize(greetings : Int32 = 0)
    @greetings = greetings
  end

  @[Pycr::PyMethod]
  def greet(word : String = "hi") : Int32
    @greetings += 1
  end

  @[Pycr::PyAttr]     # read-only unless a matching setter exists
  def greetings : Int32
    @greetings
  end

  @[Pycr::PyRepr]
  def describe : String
    "Greeter(#{@greetings})"
  end
end

Pycr.pyinit "mymodule" do
  Pycr.pyfunction def greet_everyone(names : Array(String)) : String
    "Hello, #{names.join(" and ")}!"
  end
end
```

`pyinit` generates the `PyInit_<name>` fun, registers every subclass of
`Pycr::PyObject` (both styles — there are no class lists to maintain),
and collects the module's functions. `pyfunction` also accepts a
Python-side name override: `Pycr.pyfunction is_big, def big?(n : Int64) : Bool`.

## The block style

```crystal
Pycr.pyclass Counter, "mymodule.Counter" do
  pynew def initialize(count : Int32 = 0)
    @count = count
  end

  pymethod def increment(amount : Int32 = 1) : Int32
    @count += amount
  end

  pyattr count : Int32   # read/write: emits a property and getset

  pyrepr def describe : String
    "Counter(count=#{@count})"
  end
end
```

## What the boundary does

- **Conversions**: `String`, `Bool`, `Int32`, `Int64`, `Float64`,
  `Nil` (`None`), `Bytes` in and out, `Array(T)` in and out,
  `Hash(K, V)` in and out, `Tuple` out, `NamedTuple` to dict,
  `Pycr::Callable` (any Python callable, invocable from Crystal,
  **storable**: owned through `Pycr::PyRef` — release callables you
  do not store, and the decref is deterministic; the PyRef finalizer
  is the safety net otherwise; keyword invocation via
  `call(name: value)`, positional and keyword cannot be mixed), and
  raw `Py::Object` as an escape hatch. Argument types
  come from the Crystal signatures; wrong types raise Python
  `TypeError`s.
- **Keyword arguments**: every declared argument of a pyfunction,
  pymethod or pynew can also be passed by keyword (`ParseTupleAndKeywords`;
  trailing defaults become optional positionals).
- **Exceptions**: marshalled at the boundary — `ArgumentError`→`ValueError`,
  `TypeCastError`→`TypeError`, `KeyError`→`KeyError`,
  `DivisionByZeroError`→`ZeroDivisionError`, unmapped→`RuntimeError` —
  and C-API failures pass Python's own error through untouched.
- **Iteration, len and subscripts**: `pyiter def each : Iterator(T)` /
  `@[Pycr::PyIter]` make a class iterable from Python — each `iter()`
  call yields an independent, lazy iterator; items convert through the
  iterator's element type. `pylen def size : Int32` / `@[Pycr::PyLen]`
  wire `len()`. `pygetitem def [](i : Int32) : T`,
  `pysetitem def []=(i : Int32, v : T)` and
  `pycontains def has?(v : T) : Bool` (or the `PyGetItem` /
  `PySetItem` / `PyContains` annotations) wire `obj[i]`, `obj[i] = v`
  and `v in obj`; deletion raises `NotImplementedError`, and Crystal
  errors map normally (`IndexError` etc.). `pygetter def name : T`
  defines a read-only attribute from a method; `pycompare def cmp(other
  : T, op : Int32) : Bool` wires all six comparisons (`<` `<=` `==`
  `!=` `>` `>=`, with `NotImplemented` fallback for foreign types);
  `pyadd`/`pysub`/`pymul` wire `+` `-` `*`. Exposed instances convert
  back into Python objects, so plain `pyfunction`s can be factories
  (`counter_from(9)` returns a real `Counter`). Classes with both
  `pygetitem` (integer key) and `pylen` also support Python slices —
  `wc[0:2]`, `wc[::2]`, `wc[::-1]` — with endpoints normalized by
  CPython's own `PySlice_Unpack`/`AdjustIndices`. Iterators keep the
  owner alive mid-iteration and survive GC cycles.
- **Strings and reprs**: `str()` on any exposed class calls its
  Crystal `to_s` (override `to_s` to customize); `repr()` comes from
  `pyrepr`/`@[Pycr::PyRepr]`.
- **Ownership**: Python-side instances hold a pinned pointer to the
  Crystal object; the pin registry (the only thing Boehm can see)
  keeps it alive, and `tp_dealloc` unpins. NUL-terminated strings that
  CPython keeps beyond a call (capsule names, method tables) are rooted
  the same way.
- **Scheduler**: Crystal's fiber scheduler, event loop and IO work on
  the importing thread (`sleep`, `spawn`, channels, sockets, files).
  Park fibers under `Pycr.release_gil` so other Python threads keep
  running. Foreign Python threads cannot enter the scheduler - they
  raise a clean `RuntimeError` (same as stock Crystal 1.21 user
  threads); compute-only calls work everywhere.
  `Pycr::Bridge.run { ... }` lifts that restriction for opted-in
  functions: execution contexts are pluggable, so
  `Pycr::AdoptingContext` enrolls the calling thread (public EC
  setters, single-fiber Isolated semantics - suspend blocks the
  thread in its own event loop) and the block runs with the GIL
  released. No `spawn` inside bridge blocks (it routes to the
  default EC; use blocking IO). See `notes/scheduler-spike.md`.
- **Threads and GC**: automatic Boehm collection is disabled; every
  Python thread registers itself with Boehm on entry and unregisters at
  exit, and all collections go through one mutex-serialized entry point
  triggered by an allocation-debt counter. Concurrent collectors,
  allocators and GIL-released sections coexist (see
  `notes/boehm-vs-cpython-threads.md` for why each piece is
  load-bearing). `Pycr.release_gil { ... }` drops the GIL around long
  Crystal work.
- **Waiting**: use `Pycr.sleep_seconds`, never Crystal's `sleep` — the
  fiber scheduler cannot start inside CPython (see notes).

## Status

| Layer | Status |
|---|---|
| CPython `dlopen`s a Crystal-built `.so` and runs `PyInit_*` | working, tested |
| Crystal calls back into libpython (symbols resolve from the host process, no `-lpython`) | working, tested |
| Typed conversions (see above) | working, tested |
| Exception marshalling with mapping table | working, tested |
| `pyinit`/`pyfunction`/`pyclass` DSL + annotation style, kwargs, name overrides, `pyattr` | working, tested |
| GIL release around long work | working, tested (ticker thread runs ~7M iterations during `nap`) |
| Crystal scheduler (sleep, fibers, channels, IO) on the importing thread, parks under GIL release | working, tested |
| Iteration protocol: `pyiter`/`pylen` (block + annotation styles), lazy, concurrent-safe | working, tested |
| Subscript protocols: `pygetitem`/`pysetitem`/`pycontains` (block + annotation styles) | working, tested |
| Slices over `pygetitem` + `pylen` (PySlice_Unpack/AdjustIndices) | working, tested |
| Scheduler bridge: foreign-thread scheduler access via AdoptingContext (sleep/IO/exceptions from any thread, GIL released) | working, tested |
| Factories (exposed instances from pyfunctions), `pygetter`, `pycompare`, `pyadd`/`pysub`/`pymul`, PyRef storage | working, tested |
| Boehm GC under CPython threading: registration at entry, unregistration at exit, serialized collections | working, tested (concurrent collectors + allocators + spinner + napper) |
| Pin/unpin registry for cross-runtime ownership | working, tested |

### Known limitations

- **Scheduler access is thread-affine by default**: foreign Python
  threads must go through `Pycr::Bridge.run` for scheduler work
  (sleep, blocking IO); the block runs GIL-released and must not touch
  Python objects. Direct scheduler entry from a foreign thread without
  adoption raises a clean `RuntimeError`. `Pycr.sleep_seconds` is the
  scheduler-free wait.
- `Pycr.heap_size` takes libgc's internal lock: do not call it from one
  thread while another collects.
- Macro-*emitted* annotations lose their arguments in Crystal 1.21, so
  the block DSL passes names as macro arguments instead of emitting
  `@[PyClass]` annotations.
- No packaging story yet (per-CPython-version wheels, abi3), no
  buffers/bytes conversions, no Python-side subclassing of exposed
  classes.

## Build and test

    ./build.sh
    python3 test/test_pycr.py

The full suite passes on CPython 3.14 and 3.11 with the same binary:
the module leaves the Py* symbols undefined and the loading
interpreter resolves them, and every struct/constant the bindings
mirror by hand was verified identical in 3.11's and 3.14's headers
(typeslots, PyMethodDef, PyGetSetDef, PYTHON_API_VERSION 1013,
Py_TPFLAGS_DEFAULT). New CPython minors should be checked against
that list before being trusted.

`build.sh` compiles `src/demo.cr` (swap in your own module file) and
exists because `crystal build --link-arg=-shared` cannot work on Linux
right now: Crystal mangles some symbols with `@`, and lld, bfd and gold
all misread an `@` in an exported symbol name as a symbol-version
separator. The script emits the program as a single object file,
localizes the `@`-mangled symbols with `objcopy`, and links the shared
object by hand, leaving the `Py*` symbols undefined so the interpreter
resolves them (as C extensions do on Linux).

The demo module is importable as `pycr` from the repo root.

## Example: `examples/tartrazine`

The tartrazine syntax highlighter wrapped as `import tartrazine` —
2.2 MB release binary, ~4 ms import, 388 themes, a `Lexer` class plus
`highlight()`/`tokenize()`/`themes()` functions.

Build and benchmark it:

    cd examples/tartrazine
    ./build.sh              # NOTE: builds with --release; required for the documented performance
    python3 test_tartrazine.py
    python3 bench.py        # timeit-based; compares against pygments if installed

Release-build performance (timeit best-of-5, per call, real stdlib
inputs; pygments 2.18.x for comparison):

| input | lines | tartrazine | pygments | speedup |
|---|---|---|---|---|
| small | 20 | 0.124 ms | 0.283 ms | 2.3x |
| medium | 300 | 0.827 ms | 9.148 ms | 11.1x |
| dataclasses | 1813 | 4.971 ms | 56.336 ms | 11.3x |
| large | 5689 | 16.996 ms | 205.301 ms | 12.1x |

Debug builds are roughly 5x slower — always ship extension modules
with `--release`.

## Building from source

The wheel is assembled by `packaging/build_wheel.py` (see below).

## Packaging

The `pycr` module ships as a self-contained wheel:

    ./build.sh
    python3 packaging/build_wheel.py
    pip install dist/pycr-*.whl

The wheel bundles the compiled extension (`pycr/pycr.so`, linked with
`$ORIGIN` rpath) and `libgc.so.1`, and carries multi-version tags —
one wheel installs on CPython 3.11 through 3.14 (the module resolves
Py* symbols from the loading interpreter; both 3.11 and 3.14 are
regression-tested against the same binary). Platform is
`linux_x86_64` (glibc); macOS and musl are future work. Clean-venv
installs are verified, including subclassing, factories, and the
foreign-thread bridge from the installed package.

CI (`.github/workflows/ci.yml`) runs the full test battery on CPython
3.11 and 3.14, lint (ameba + format check), and builds the wheel as
an artifact on every push.

## Roadmap

1. `PyRef` as the general storable reference everywhere (works for
   arbitrary objects via remember/recall-style APIs).
2. Attributes with getters only in annotation style are done; block
   style has `pygetter`.
3. Scheduler bridge scale-up: multi-fiber AdoptingContext (spawn inside bridge blocks, currently routed to the default EC per Isolated semantics); context lifecycle on foreign-thread death.
4. Packaging: manylinux compliance (vendor bdwgc statically or auditwheel-repair), macOS + musl builds, sdist with a Crystal toolchain fallback.

## License

MIT
