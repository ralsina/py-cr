# py-cr (temporary name)

A framework for writing Python extension modules in Crystal: compile
Crystal code into a CPython-importable `.so`, the way
[PyO3](https://github.com/PyO3/pyo3) does it for Rust and
[nimpy](https://github.com/yglukhov/nimpy) for Nim. The framework is
library-agnostic: any Crystal code can be exposed, and `src/demo.cr`
is just one example module used as the framework's test surface.

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
  errors map normally (`IndexError` etc.). Iterators keep the owner
  alive mid-iteration and survive GC cycles.
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
  threads); compute-only calls work everywhere. See
  `notes/scheduler-spike.md`.
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
| Boehm GC under CPython threading: registration at entry, unregistration at exit, serialized collections | working, tested (concurrent collectors + allocators + spinner + napper) |
| Pin/unpin registry for cross-runtime ownership | working, tested |

### Known limitations

- **Scheduler access is thread-affine**: foreign Python threads cannot
  run fibers/IO/sleep (clean `RuntimeError`); funnel those calls to
  the importing thread. `Pycr.sleep_seconds` is the scheduler-free
  wait for foreign threads.
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

## Roadmap

1. `PyRef` as the general storable reference for arbitrary Python
   objects (it exists; conversions and docs are callable-focused so
   far).
2. Attributes with getters only in block style; class methods and
   constructors as `pyfunction`s; `__str__`, rich comparison, arithmetic
   slots.
3. Sequence protocol extras (slices).
4. Scheduler bridge: funnel foreign-thread scheduler work to the importing thread's EC (condvar wait under `release_gil`) so IO-capable Crystal calls work from any Python thread.
5. Packaging: cibuildwheel, per-CPython-version wheels, then
   limited-API/abi3 discipline.

The first real example module lives in `examples/tartrazine`: the
tartrazine syntax highlighter as `import tartrazine` (highlight,
tokenize, a Lexer class, themes), 4.7 MB, ~4 ms import, 1.7-2.5x
faster than pygments on the initial benchmarks.

## License

MIT
