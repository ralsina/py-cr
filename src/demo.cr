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
