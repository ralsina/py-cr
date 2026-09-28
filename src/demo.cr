# An example extension module built with the py-cr DSL.
#
# This file is the whole module: functions, classes in both DSL styles,
# the generated PyInit_pycr entry point. Build with ./build.sh and
# `import pycr`.

require "./pycr"

# Capsule destructor for the box/unbox pin-registry demo; called by
# CPython (GIL held) when the capsule's refcount reaches zero.
def capsule_unpin(capsule : Py::Object)
  Pycr.unpin_capsule(capsule)
end

# CallbackBox: demonstrates storable callables — a Python callable
# attached during one call, kept alive in a Crystal ivar (owned via
# PyRef), and invoked from later calls.
@[Pycr::PyClass("pycr.CallbackBox")]
class CallbackBox < Pycr::PyObject
  @[Pycr::PyNew]
  def initialize
    # nil assignment in initialize makes the ivar nilable; Crystal
    # infers (Callable | Nil) from the attach assignment.
    @callback = nil
    @invocations = 0
  end

  @[Pycr::PyMethod]
  def attach(func : Pycr::Callable) : Nil
    @callback = func
  end

  @[Pycr::PyMethod]
  def detach : Nil
    callback = @callback
    callback.release unless callback.nil?  # deterministic decref
    @callback = nil                        # finalizer is the safety net
  end

  @[Pycr::PyMethod]
  def invoke(value : Int64) : Int64
    callback = @callback
    raise ArgumentError.new("no callback attached") if callback.nil?
    @invocations += 1
    Pycr::Conversions.from_python(callback.call(value), Int64)
  end

  @[Pycr::PyAttr]
  def invocations : Int32
    @invocations
  end

  @[Pycr::PyRepr]
  def describe : String
    "CallbackBox(#{@invocations} invocations)"
  end
end

# Greeter: the annotation style (PyO3-like). Discovered and registered
# automatically by pyinit via Pycr::PyObject.all_subclasses.
@[Pycr::PyClass("pycr.Greeter")]
class Greeter < Pycr::PyObject
  @[Pycr::PyNew]
  def initialize(greetings : Int32 = 0)
    @greetings = greetings
  end

  @[Pycr::PyMethod]
  def greet(word : String = "hi") : Int32
    @greetings += 1
  end

  @[Pycr::PyAttr]
  def greetings : Int32
    @greetings
  end

  @[Pycr::PyRepr]
  def describe : String
    "Greeter(#{@greetings})"
  end
end

Pycr.pyinit "pycr" do
  Pycr.pyfunction def hello : String
    "Hello from Crystal!"
  end

  Pycr.pyfunction def echo(name : String) : String
    "Hello, #{name}!"
  end

  Pycr.pyfunction def length(text : String) : Int32
    text.bytesize
  end

  Pycr.pyfunction def version : String
    "Crystal #{Crystal::VERSION}"
  end

  Pycr.pyfunction def boom : Nil
    raise "boom from Crystal"
  end

  Pycr.pyfunction def fail_value : Nil
    raise ArgumentError.new("this becomes ValueError")
  end

  Pycr.pyfunction def fail_key : Nil
    raise KeyError.new("this becomes KeyError")
  end

  # Allocation churn WITHOUT an explicit collect: lets tests tell
  # automatic (allocation-triggered) collections apart from forced ones.
  Pycr.pyfunction def churn(mb : Int64) : Int64
    total_bytes = 0_i64
    mb.clamp(0_i64, 4096_i64).times do |iteration|
      chunk = "Churn filler #{iteration} " * 32768
      total_bytes += chunk.bytesize
    end
    total_bytes
  end

  Pycr.pyfunction def stress(mb : Int64) : Int64
    total_bytes = 0_i64
    mb.clamp(0_i64, 4096_i64).times do |iteration|
      chunk = "GC stress filler #{iteration} " * 32768
      total_bytes += chunk.bytesize
    end
    Pycr.safe_collect
    total_bytes
  end

  # Explicit, serialized collection: the one sanctioned entry point.
  Pycr.pyfunction def gc : Nil
    Pycr.safe_collect
  end

  Pycr.pyfunction def heap : Int64
    Pycr.heap_size
  end

  # Releases the GIL while sleeping: proof that other Python threads
  # keep running during long Crystal-side work.
  Pycr.pyfunction def nap(seconds : Float64) : Nil
    Pycr.release_gil { Pycr.sleep_seconds seconds }
  end

  # Raw-object round-trip: box/unbox exercise the pin registry through
  # PyCapsule destructors, using the Py::Object conversion escape hatch.
  Pycr.pyfunction def box(text : String) : Py::Object
    Pycr.pin(text.as(Void*))
    Py.PyCapsule_New(text.as(Void*), Pycr.eternal_cstr(CAPSULE_NAME), ->capsule_unpin(Py::Object))
  end

  Pycr.pyfunction def unbox(capsule : Py::Object) : String
    pointer = Py.PyCapsule_GetPointer(capsule, Pycr.eternal_cstr(CAPSULE_NAME))
    raise "argument is not a #{CAPSULE_NAME} capsule" if pointer.null?
    unless Pycr.pinned?(pointer)
      raise ArgumentError.new("capsule contents were already unpinned")
    end
    pointer.as(String)
  end

  Pycr.pyfunction def pinned_count : Int32
    Pycr.registry.size
  end

  Pycr.pyfunction def add(first : Int64, second : Int64) : Int64
    first + second
  end

  # Crystal predicate naming on this side, Python naming on the other.
  Pycr.pyfunction is_big, def big?(number : Int64) : Bool
    number > 1_000_000
  end

  Pycr.pyfunction def mean(numbers : Array(Float64)) : Float64
    raise ArgumentError.new("mean of an empty list is undefined") if numbers.empty?
    numbers.sum / numbers.size
  end

  Pycr.pyfunction def double_all(numbers : Array(Int32)) : Array(Int32)
    numbers.map { |number| number * 2 }
  end

  Pycr.pyfunction def word_count(words : Array(String)) : Hash(String, Int32)
    counts = Hash(String, Int32).new
    words.each { |word| counts[word] = (counts[word]? || 0) + 1 }
    counts
  end

  # Dicts in and out, tuples out.
  Pycr.pyfunction def merge_counts(base : Hash(String, Int32), extra : Hash(String, Int32)) : Hash(String, Int32)
    result = base.dup
    extra.each { |word, count| result[word] = (result[word]? || 0) + count }
    result
  end

  Pycr.pyfunction def min_max(numbers : Array(Int32)) : Tuple(Int32, Int32)
    {numbers.min, numbers.max}
  end

  Pycr.pyfunction def nothing : Nil
  end

  # Three trailing optionals, mirroring the example module's highlight()
  Pycr.pyfunction def echo3(text : String, flag : Bool = false, other : Bool = false, third : Bool = false) : String
    "#{text}|#{flag}|#{other}|#{third}"
  end

  # Python callables as arguments: the wrapper borrows the reference
  # for the duration of the call.
  Pycr.pyfunction def apply_func(func : Pycr::Callable, value : Int64) : Int64
    result = func.call(value)
    Pycr::Conversions.from_python(result, Int64)
  end

  Pycr.pyfunction def map_ints(func : Pycr::Callable, values : Array(Int32)) : Array(Int32)
    values.map { |value| Pycr::Conversions.from_python(func.call(value), Int32) }
  end

  Pycr.pyfunction def call_two(func : Pycr::Callable, first : String, second : String) : String
    result = func.call(first, second)
    Pycr::Conversions.from_python(result, String)
  end

  Pycr.pyfunction def call_plain(func : Pycr::Callable) : Bool
    result = func.call
    Pycr::Conversions.from_python(result, Bool)
  end

  # Spike introspection: which thread ran the last PyRef finalizer
  # (-1 unknown, 0 foreign thread, 1 bootstrap thread).
  Pycr.pyfunction def pyref_finalizer_same_thread : Int32
    Pycr::PyRef.last_finalizer_same_thread
  end

  # Bytes in and out.
  Pycr.pyfunction def hexdigest(data : Bytes) : String
    data.hexstring
  end

  Pycr.pyfunction def repeat_bytes(data : Bytes, times : Int32) : Bytes
    result = Bytes.new(data.size * times)
    result.each_index { |index| result[index] = data[index % data.size] }
    result
  end

  # --- Scheduler spike probes (notes/scheduler-spike.md) --------------------
  # One probe per layer of Crystal's runtime that historically crashed in
  # library mode: Thread.current -> root Fiber -> event loop.

  # Rung 1a: the original crasher.
  Pycr.pyfunction def crystal_sleep(seconds : Float64) : Nil
    sleep seconds
  end

  # Rung 1b: fiber spawn + channel round-trip (starts the scheduler).
  Pycr.pyfunction def fiber_roundtrip(value : Int64) : Int64
    channel = Channel(Int64).new
    spawn do
      channel.send(value * 2)
    end
    channel.receive
  end

  # Rung 1c: many fibers fanned out and joined.
  Pycr.pyfunction def spawn_many(count : Int32) : Int64
    channel = Channel(Int64).new
    count.times do |index|
      spawn do
        channel.send(index.to_i64 * 2)
      end
    end
    total = 0_i64
    count.times { total += channel.receive }
    total
  end

  # Rung 1d: file IO.
  Pycr.pyfunction def read_file(path : String) : String
    File.read(path)
  end

  # Rung 2: fiber park under GIL release — the starvation test.
  Pycr.pyfunction def fiber_sleep_under_gil_release(seconds : Float64) : Nil
    Pycr.release_gil { sleep seconds }
  end

  # Block-style classes are registered by the same pyinit.

  Pycr.pyclass Counter, "pycr.Counter" do
    pynew def initialize(count : Int32 = 0)
      @count = count
    end

    pymethod def increment(amount : Int32 = 1) : Int32
      @count += amount
    end

    pymethod def value : Int32
      @count
    end

    pymethod def reset : Nil
      @count = 0
    end

    pyattr count : Int32

    pyrepr def describe : String
      "Counter(count=#{@count})"
    end
  end

  Pycr.pyclass WordCounter, "pycr.WordCounter" do
    pynew def initialize
      @words = [] of String
    end

    pymethod def add(word : String) : Int32
      @words << word
      @words.size
    end

    pymethod def count : Int32
      @words.size
    end

    pyrepr def summary : String
      "#{@words.size} words: #{@words.join(", ")}"
    end
  end
end
