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
  `Nil` (`None`), `Array(T)` in and out, `Hash(K, V)` in and out,
  `Tuple` out, `Pycr::Callable` (any Python callable, invocable from
  Crystal; callback exceptions propagate as themselves), and raw
  `Py::Object` as an escape hatch. Argument types
  come from the Crystal signatures; wrong types raise Python
  `TypeError`s.
- **Keyword arguments**: every declared argument of a pyfunction,
  pymethod or pynew can also be passed by keyword (`ParseTupleAndKeywords`;
  trailing defaults become optional positionals).
- **Exceptions**: marshalled at the boundary — `ArgumentError`→`ValueError`,
  `TypeCastError`→`TypeError`, `KeyError`→`KeyError`,
  `DivisionByZeroError`→`ZeroDivisionError`, unmapped→`RuntimeError` —
  and C-API failures pass Python's own error through untouched.
- **Ownership**: Python-side instances hold a pinned pointer to the
  Crystal object; the pin registry (the only thing Boehm can see)
  keeps it alive, and `tp_dealloc` unpins. NUL-terminated strings that
  CPython keeps beyond a call (capsule names, method tables) are rooted
  the same way.
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
| Boehm GC under CPython threading: registration at entry, unregistration at exit, serialized collections | working, tested (concurrent collectors + allocators + spinner + napper) |
| Pin/unpin registry for cross-runtime ownership | working, tested |

### Known limitations

- **Crystal's scheduler cannot start** inside CPython (`sleep`, fibers,
  async IO all segfault); `Pycr.sleep_seconds` is the safe wait.
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

1. Callables with keyword arguments; owned (storable) callable
   references with reference-count management.
2. Attributes with getters only in block style; class methods and
   constructors as `pyfunction`s; `__str__`, rich comparison, arithmetic
   slots.
3. Buffers/bytes conversions; `NamedTuple`.
4. Packaging: cibuildwheel, per-CPython-version wheels, then
   limited-API/abi3 discipline.

The first real example module lives in `examples/tartrazine`: the
tartrazine syntax highlighter as `import tartrazine` (highlight,
tokenize, a Lexer class, themes), 4.7 MB, ~4 ms import, 1.7-2.5x
faster than pygments on the initial benchmarks.

## License

MIT
