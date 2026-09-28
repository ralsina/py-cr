# py-cr: a framework for writing Python extension modules in Crystal.
#
# The CPython surface is declared by hand in `lib Py`. There is no
# @[Link] on it: on Linux, extension modules leave the Py* symbols
# undefined and the interpreter resolves them from its own process
# image, exactly like a C extension would.
#
# Layout:
#
#   pycr.cr               libpython bindings and boundary helpers
#   pycr/conversions.cr   typed conversions between Crystal and CPython
#   pycr/macros.cr        the pyinit / pyclass DSL and annotations
#   pycr/classes.cr       heap-type registration machinery
#   ../demo.cr            an example module built with the DSL

require "./pycr/conversions"
require "./pycr/pyref"
require "./pycr/callable"
require "./pycr/macros"
require "./pycr/classes"

lib Py
  alias Object = Void*

  struct MethodDef
    name : UInt8*
    meth : (Object, Object, Object) -> Object
    flags : Int32
    doc : UInt8*
  end

  # Mirror of PyGetSetDef (descrobject.h) for pyattr attributes.
  struct GetSetDef
    name : UInt8*
    get : (Object, Void*) -> Object
    set : (Object, Object, Void*) -> Int32
    doc : UInt8*
    closure : Void*
  end

  # Byte-for-byte mirror of CPython's PyModuleDef (single-phase init:
  # m_slots is null). The field order and the m_name/m_doc fields after
  # the embedded PyModuleDef_Base matter: get them wrong and CPython
  # reads garbage as the module name.
  struct ModuleDef
    ob_refcnt : Int64 # PyObject.ob_refcnt
    ob_type : Void*   # PyObject.ob_type
    m_init : Void* -> Object
    m_index : Int64
    m_copy : Object
    m_name : UInt8* # module name, must match the .so's
    m_doc : UInt8*  # module docstring or null
    m_size : Int64  # -1: static per-interpreter state
    m_methods : MethodDef*
    m_slots : Void* # PyModuleDef_Slot* or null
    m_reload : Void*
    m_traverse : Void*
    m_clear : Void*
    m_free : (Void*) -> Void
  end

  struct TypeSlot
    slot : Int32
    slot_pad : Int32
    pfunc : Void*
  end

  # Same 16-byte layout as TypeSlot, but with a typed pfunc so proc
  # literals auto-convert on assignment (Classes writes slots through
  # these shapes and copies the bytes into the slot array).
  struct TypeSlotNew
    slot : Int32
    slot_pad : Int32
    pfunc : (Object, Object, Object) -> Object
  end

  struct TypeSlotUnary
    slot : Int32
    slot_pad : Int32
    pfunc : (Object) -> Object
  end

  struct TypeSlotDealloc
    slot : Int32
    slot_pad : Int32
    pfunc : (Object) -> Void
  end

  struct TypeSlotLen
    slot : Int32
    slot_pad : Int32
    pfunc : (Object) -> Int64
  end

  struct TypeSlotSubscript
    slot : Int32
    slot_pad : Int32
    pfunc : (Object, Object) -> Object
  end

  struct TypeSlotAssSubscript
    slot : Int32
    slot_pad : Int32
    pfunc : (Object, Object, Object) -> Int32
  end

  struct TypeSlotContains
    slot : Int32
    slot_pad : Int32
    pfunc : (Object, Object) -> Int32
  end

  # Mirror of PyType_Spec (object.h), used with PyType_FromSpec.
  struct TypeSpec
    name : UInt8*
    basicsize : Int32
    itemsize : Int32
    flags : UInt32
    slots : TypeSlot*
  end

  fun PyModule_Create2(def : ModuleDef*, apiver : Int32) : Object
  fun PyModule_AddObject(module : Object, name : UInt8*, value : Object) : Int32
  fun PyUnicode_FromString(s : UInt8*) : Object
  fun PyUnicode_AsUTF8AndSize(obj : Object, size : Int64*) : UInt8*
  fun PyLong_FromLongLong(v : Int64) : Object
  fun PyLong_AsLongLong(obj : Object) : Int64
  fun PyBool_FromLong(v : Int64) : Object
  fun PyFloat_FromDouble(v : Float64) : Object
  fun PyFloat_AsDouble(obj : Object) : Float64
  fun PyObject_IsTrue(obj : Object) : Int32
  fun Py_BuildValue(format : UInt8*, ...) : Object
  fun PyArg_ParseTuple(args : Object, format : UInt8*, ...) : Int32
  fun PyArg_ParseTupleAndKeywords(args : Object, kwargs : Object, format : UInt8*, keywords : UInt8**, ...) : Int32
  fun PyErr_SetString(exc : Object, msg : UInt8*) : Void
  fun PyErr_Occurred : Object
  fun PyErr_Clear : Void
  fun PyList_New(size : Int64) : Object
  fun PyList_Size(list : Object) : Int64
  fun PyList_GetItem(list : Object, index : Int64) : Object
  fun PyList_SetItem(list : Object, index : Int64, item : Object) : Int32
  fun PyTuple_New(size : Int64) : Object
  fun PyTuple_SetItem(tuple : Object, index : Int64, item : Object) : Int32
  fun PyDict_New : Object
  fun PyDict_Size(dict : Object) : Int64
  fun PyDict_SetItem(dict : Object, key : Object, value : Object) : Int32
  fun PyDict_Next(dict : Object, position : Int64*, key : Object*, value : Object*) : Int32
  fun PyCapsule_New(pointer : Void*, name : UInt8*, destructor : (Object) -> Void) : Object
  fun PyCapsule_GetPointer(capsule : Object, name : UInt8*) : Void*
  fun PyBytes_FromStringAndSize(string : UInt8*, size : Int64) : Object
  fun PyBytes_AsStringAndSize(obj : Object, buffer : UInt8**, size : Int64*) : Int32
  fun PyIter_Check(obj : Object) : Int32
  fun PyCallable_Check(obj : Object) : Int32
  fun PyObject_Call(callable : Object, args : Object, kwargs : Object) : Object
  fun PyType_FromSpec(spec : TypeSpec*) : Object
  fun PyType_GenericAlloc(type : Object, items : Int64) : Object
  fun PyObject_Free(ptr : Void*) : Void
  fun PyEval_SaveThread : Void*
  fun PyEval_RestoreThread(thread_state : Void*) : Void
  fun Py_IncRef(obj : Object) : Void
  fun Py_DecRef(obj : Object) : Void

  # C global data symbols: `PyObject *PyExc_*`. Declaring them as lib
  # variables means reading them loads the PyObject* stored at the symbol.
  $runtime_error = PyExc_RuntimeError : Object
  $type_error = PyExc_TypeError : Object
  $value_error = PyExc_ValueError : Object
  $key_error = PyExc_KeyError : Object
  $index_error = PyExc_IndexError : Object
  $zero_division_error = PyExc_ZeroDivisionError : Object
  $not_implemented_error = PyExc_NotImplementedError : Object
end

METH_VARARGS  = 0x0001
METH_KEYWORDS = 0x0002

# The version CPython was compiled with; PyModule_Create2 accepts it as-is.
PYTHON_API_VERSION = 1013

# From typeslots.h in the python3.14 headers (identical on 3.11 and 3.14).
PY_MP_ASS_SUBSCRIPT =  3
PY_MP_SUBSCRIPT     =  5
PY_SQ_CONTAINS      = 41
PY_TP_DEALLOC       = 52
PY_TP_METHODS       = 64
PY_TP_NEW           = 65
PY_TP_REPR          = 66
PY_TP_ITER          = 62
PY_TP_ITERNEXT      = 63
PY_TP_STR           = 70
PY_TP_GETSET        = 73
PY_MP_LENGTH        =  4

# object.h: HAVE_STACKLESS_EXTENSION is 0 on stock builds, so DEFAULT is 0.
PY_TPFLAGS_DEFAULT = 0_u32

CAPSULE_NAME = "pycr.pinned_string"

lib LibCrystalMain
  @[Raises]
  fun __crystal_main(argc : Int32, argv : UInt8**)
end

# Boehm cannot see threads CPython created before our .so was dlopened
# (libgc's pthread interception only catches threads created after the
# library is loaded), so an unregistered Python thread that allocates
# or collects aborts with "Collecting from unknown thread". Register
# each calling thread once, at boundary entry.
lib LibC
  fun pthread_getspecific(key : UInt32) : Void*
  fun pthread_setspecific(key : UInt32, value : Void*) : Int32
  fun pthread_key_create(key : UInt32*, destructor : (Void*) -> Void) : Int32
  fun pthread_mutex_lock(mutex : PthreadMutexT*) : Int32
  fun pthread_mutex_unlock(mutex : PthreadMutexT*) : Int32
end

lib LibGC
  # Full C GC_stack_base (Crystal's own LibGC declares only mem_base);
  # separate name to avoid clashing with LibGC::StackBase.
  struct FullStackBase
    mem_base : Void*
    reg_base : Void*
  end

  fun get_stack_base = GC_get_stack_base(sb : FullStackBase*) : Int32
  fun register_my_thread = GC_register_my_thread(sb : FullStackBase*) : Int32
  fun unregister_my_thread = GC_unregister_my_thread : Int32
  fun allow_register_threads = GC_allow_register_threads : Nil
  fun get_heap_size = GC_get_heap_size : Word
end

# Runs at thread exit via the pthread key destructor: CPython threads
# die without notice, and a stale registration makes the next
# stop-the-world try to suspend a dead pthread (which aborts with
# "Signals delivery fails constantly").
def boehm_thread_exit(_value : Void*)
  LibGC.unregister_my_thread
end

module Pycr
  # Raw pthread TLS, NOT @[ThreadLocal]: Crystal's thread-local class
  # vars go through Thread.current, which crashes on foreign threads
  # because the scheduler never initialized in library mode. Nilable
  # without an initializer for the same reason.
  @@boehm_tls_key : UInt32?

  def self.boehm_tls_key : UInt32
    @@boehm_tls_key ||= begin
      key = uninitialized UInt32
      LibC.pthread_key_create(pointerof(key), ->boehm_thread_exit(Void*))
      key
    end
  end

  # See the LibGC extension above: idempotent per thread, cheap after
  # the first call.
  def self.ensure_thread_registered : Nil
    return unless LibC.pthread_getspecific(boehm_tls_key).null?
    LibC.pthread_setspecific(boehm_tls_key, Pointer(Void).new(1_u64))
    LibGC.allow_register_threads
    stack_base = LibGC::FullStackBase.new
    if LibGC.get_stack_base(pointerof(stack_base)) == 0
      LibGC.register_my_thread(pointerof(stack_base))
    end
  end

  # sizeof(PyObject): refcount + type pointer. Instance data (the pinned
  # Crystal pointer) lives right after it.
  INSTANCE_DATA_OFFSET = 16

  # Raised when a CPython C-API call has failed and already set Python's
  # error indicator; py_call passes it through untouched so Python sees
  # its own TypeError/OverflowError/... instead of a generic error.
  class PythonError < Exception
  end

  # Base class for every class exposed to Python, both the pyclass block
  # DSL and the annotation style. Also the discovery root for the pyinit
  # macro, which registers PyObject.all_subclasses.
  class PyObject
    def self.py_dealloc(instance : Py::Object) : Nil
      Pycr.unpin(Pycr.instance_data(instance))
      Py.PyObject_Free(instance)
    end
  end

  # Everything is initialized lazily from PyInit: in library mode we do
  # not want to depend on load-time initializers having run.

  def self.module_definition : Py::ModuleDef*
    @@module_definition ||= Pointer(Py::ModuleDef).malloc(1)
  end

  class_property method_table : Py::MethodDef* = Pointer(Py::MethodDef).null

  # The pin registry: every Crystal object handed to Python stays rooted
  # here until the Python wrapper is destroyed and calls back to unpin.
  # This is the core of the cross-runtime ownership story.
  def self.registry : Set(Void*)
    @@registry ||= Set(Void*).new
  end

  def self.pin(pointer : Void*) : Nil
    registry << pointer
  end

  def self.unpin(pointer : Void*) : Nil
    registry.delete(pointer)
  end

  def self.pinned?(pointer : Void*) : Bool
    registry.includes?(pointer)
  end

  # Keyword-name lists for PyArg_ParseTupleAndKeywords, cached per
  # function and rooted through this hash (Boehm never sees CPython's
  # heap, so anything CPython points at must be rooted on our side).
  def self.kwlists : Hash(String, Pointer(UInt8*))
    @@kwlists ||= Hash(String, Pointer(UInt8*)).new
  end

  def self.kwlist(key : String, names : Array(String)) : Pointer(UInt8*)
    kwlists[key] ||= begin
      list = Pointer(UInt8*).malloc(names.size + 1)
      names.each_with_index { |name, index| list[index] = cstr(name) }
      list[names.size] = Pointer(UInt8).null
      list
    end
  end

  # NUL-terminated buffers that CPython keeps pointers to beyond a
  # single call (capsule names): Boehm cannot see CPython's heap, so
  # they must be rooted here or they get collected out from under it.
  def self.eternal_strings : Hash(String, UInt8*)
    @@eternal_strings ||= Hash(String, UInt8*).new
  end

  def self.eternal_cstr(text : String) : UInt8*
    eternal_strings[text] ||= cstr(text)
  end

  # Copies a Crystal string into a fresh NUL-terminated buffer. Crystal
  # strings are not guaranteed to be NUL-terminated, so this is the only
  # way bytes cross into C.
  def self.cstr(text : String) : UInt8*
    note_allocation(text.bytesize + 1)
    buffer = Pointer(UInt8).malloc(text.bytesize + 1)
    buffer.copy_from(text.to_unsafe, text.bytesize)
    buffer[text.bytesize] = 0_u8
    buffer
  end

  # --- Collection policy ----------------------------------------------------
  #
  # Boehm collections from two active CPython threads at once abort
  # inside libgc's stop-the-world, and even reads like GC_get_heap_size
  # take libgc's internal lock, putting a concurrent reader into an
  # unsuspendable state mid-collection. So: automatic collection is
  # disabled at bootstrap; the hot path tracks allocation debt with a
  # plain atomic (no libgc calls at all); and every collection goes
  # through safe_collect — serialized by a raw pthread mutex (Crystal's
  # Mutex routes contended locks through Thread.current, which crashes
  # on foreign threads) — from points where the caller holds the GIL.

  # Collect once this much allocation has gone through the boundary,
  # or once the real heap has grown this much since the last check.
  COLLECTION_DEBT_BYTES = 64 * 1024 * 1024

  # Sample the real heap size every N boundary calls.
  COLLECTION_CHECK_INTERVAL = 32

  # A zeroed pthread_mutex_t is PTHREAD_MUTEX_INITIALIZER on glibc, and
  # GC.malloc returns zeroed memory; the class var roots the allocation.
  @@collect_mutex : Pointer(LibC::PthreadMutexT)?

  def self.collect_mutex : LibC::PthreadMutexT*
    @@collect_mutex ||= Pointer(LibC::PthreadMutexT).malloc(1)
  end

  # The only sanctioned way to collect. Boehm must be re-enabled around
  # the collection: with GC disabled, GC_gcollect does not reclaim.
  def self.safe_collect : Nil
    LibC.pthread_mutex_lock(collect_mutex)
    @@safe_collect_depth.add(1)
    begin
      LibGC.enable
      GC.collect
      # Drain queued Boehm finalizers synchronously on this thread
      # (GIL held): PyRef decrefs then happen deterministically at
      # framework-chosen collection points instead of whenever libgc
      # feels like running them.
      LibGC.invoke_finalizers
      LibGC.disable
    ensure
      @@safe_collect_depth.sub(1)
      LibC.pthread_mutex_unlock(collect_mutex)
    end
  end

  def self.safe_collect_disabled : Bool
    @@safe_collect_depth.get != 0
  end

  @@boundary_calls = Atomic(Int64).new(0)
  @@heap_at_collect = Atomic(Int64).new(-1)
  @@debt_bytes = Atomic(Int64).new(0)

  # Current Boehm heap size in bytes. NOT safe to call from one thread
  # while another collects: it takes libgc's internal lock.
  def self.heap_size : Int64
    LibGC.get_heap_size.to_i64
  end

  # Called at every boundary entry: every COLLECTION_CHECK_INTERVAL
  # calls, samples the real heap size and collects on 64MB of growth.
  # The allocation-debt counter alone is blind to allocation inside
  # Crystal bodies (the majority), which the soak test caught as
  # unbounded growth. Atomics, not plain class vars: several Python
  # threads reach this at once, and a skewed count only shifts when a
  # check happens.
  def self.note_boundary_call : Nil
    return if safe_collect_disabled
    calls = @@boundary_calls.add(1)
    return unless calls % COLLECTION_CHECK_INTERVAL == 0
    baseline = @@heap_at_collect.get
    return unless baseline >= 0
    return unless heap_size - baseline > COLLECTION_DEBT_BYTES
    safe_collect
    @@heap_at_collect.set(heap_size)
  end

  # Accounts for Crystal-side boundary allocation and collects when
  # the debt crosses the threshold; complements the heap sampling for
  # conversion-heavy workloads that allocate in small pieces.
  def self.note_allocation(bytes : Int) : Nil
    return if safe_collect_disabled
    debt = @@debt_bytes.add(bytes.to_i64)
    return unless debt > COLLECTION_DEBT_BYTES
    @@debt_bytes.swap(0)
    safe_collect
  end

  # Set while the framework itself collects, so its own accounting
  # cannot recurse into another collection.
  @@safe_collect_depth = Atomic(Int32).new(0)

  # Runs a block and guarantees no Crystal exception ever crosses the C
  # boundary: errors from the C API (PythonError) pass through with the
  # Python error indicator already set, everything else is mapped
  # through the exception table.
  #
  # Uses a yield block rather than a typed &block: the typed-Proc
  # conversion crashes Crystal 1.21's compiler when the block body calls
  # an overloaded method with a NoReturn argument (raise-only defs); see
  # notes/crystal-1.21-no-return-proc-bug.cr.
  def self.py_call(&) : Py::Object
    ensure_thread_registered
    note_boundary_call
    yield
  rescue PythonError
    Pointer(Void).null.as(Py::Object)
  rescue exception : Exception
    message = "#{exception.class.name}: #{exception.message || "no message"}"
    Py.PyErr_SetString(python_exception_for(exception), cstr(message))
    Pointer(Void).null.as(Py::Object)
  end

  # py_call for C slots returning ssize_t (mp_length and friends).
  def self.py_call_int64(&) : Int64
    yield
  rescue PythonError
    -1_i64
  rescue exception : Exception
    message = "#{exception.class.name}: #{exception.message || "no message"}"
    Py.PyErr_SetString(python_exception_for(exception), cstr(message))
    -1_i64
  end

  # py_call for functions that report failure with -1 (attribute
  # setters and other int-returning C slots).
  def self.py_call_int(&) : Int32
    ensure_thread_registered
    note_boundary_call
    yield
  rescue PythonError
    -1
  rescue exception : Exception
    message = "#{exception.class.name}: #{exception.message || "no message"}"
    Py.PyErr_SetString(python_exception_for(exception), cstr(message))
    -1
  end

  # Suspends the calling thread without touching Crystal's scheduler.
  # On the importing thread, Crystal's sleep works (see
  # notes/scheduler-spike.md); this remains the safe wait on foreign
  # Python threads, where the scheduler is unavailable, and anywhere
  # you want to avoid scheduler dependency.
  def self.sleep_seconds(seconds : Float64) : Nil
    request = LibC::Timespec.new
    request.tv_sec = seconds.to_i64
    request.tv_nsec = ((seconds % 1.0) * 1_000_000_000).to_i64
    remaining = LibC::Timespec.new
    LibC.nanosleep(pointerof(request), pointerof(remaining))
  end

  # Releases the GIL for the duration of the block; wrap long Crystal
  # work so other Python threads can run.
  def self.release_gil(&)
    thread_state = Py.PyEval_SaveThread
    begin
      yield
    ensure
      Py.PyEval_RestoreThread(thread_state)
    end
  end

  # Maps Crystal exceptions to Python ones; subclasses match via the
  # case's is_a? semantics, unmapped exceptions surface as RuntimeError.
  def self.python_exception_for(exception : Exception) : Py::Object
    case exception
    when ArgumentError       then Py.value_error
    when TypeCastError       then Py.type_error
    when KeyError            then Py.key_error
    when IndexError          then Py.index_error
    when DivisionByZeroError then Py.zero_division_error
    when NotImplementedError then Py.not_implemented_error
    else                          Py.runtime_error
    end
  end

  # Reads the pinned Crystal pointer stored in a heap-type instance.
  def self.instance_data(instance : Py::Object) : Void*
    (instance.as(UInt8*) + INSTANCE_DATA_OFFSET).as(Pointer(Void*)).value
  end

  # Allocates the Python-side instance, pins the Crystal object, and
  # stores its pointer after the PyObject header. Used by the thunks
  # the DSL generates for constructors.
  def self.py_wrap(instance : Object, subtype : Py::Object) : Py::Object
    note_allocation(64)
    pin(instance.as(Void*))
    allocated = Py.PyType_GenericAlloc(subtype, 0)
    if allocated.null?
      unpin(instance.as(Void*))
      return Pointer(Void).null.as(Py::Object)
    end
    (allocated.as(UInt8*) + INSTANCE_DATA_OFFSET).as(Pointer(Void*)).value = instance.as(Void*)
    allocated
  end

  def self.set_method(table : Py::MethodDef*, index : Int32, name : String,
                      implementation : (Py::Object, Py::Object, Py::Object) -> Py::Object) : Nil
    entry = table + index
    entry.value.name = cstr(name)
    entry.value.meth = implementation
    entry.value.flags = METH_VARARGS | METH_KEYWORDS
  end

  # Called by the PyInit fun the pyinit macro generates: resets the
  # module definition and allocates a fresh method table.
  def self.bootstrap_module(name : String, function_count : Int32) : Nil
    # The blessed runtime bootstrap (GC, Thread, Fiber, Once class
    # vars) that C's main runs in normal programs but library mode
    # never does; without it, Thread.current and __crystal_once crash
    # on any thread. PyInit is single-threaded, before any thunk runs.
    Crystal.init_runtime
    # Constants with runtime initializers (Regex literals, baked file
    # systems, ...) are initialized eagerly by the compiler-generated
    # __crystal_main, not lazily through __crystal_once: without this
    # call their slots stay null and first use segfaults. Top-level
    # statements run too, which is what a normal program does anyway.
    begin
      argv = Pointer(Pointer(UInt8)).malloc(2)
      argv[0] = cstr(name)
      argv[1] = Pointer(UInt8).null
      LibCrystalMain.__crystal_main(1, argv)
    rescue exception : Exception
      message = cstr("pycr: program initializers failed: #{exception.class.name}: #{exception.message || "no message"}\n")
      LibC.write(2, message, LibC.strlen(message))
    end
    # Collections happen only where the framework chooses (see the
    # collection policy above).
    LibGC.disable
    @@heap_at_collect.set(heap_size)
    definition = module_definition
    Slice.new(definition, 1).fill(Py::ModuleDef.new)
    definition.value.ob_refcnt = 1
    definition.value.m_name = cstr(name)
    definition.value.m_size = -1 # static, single-phase module
    self.method_table = Pointer(Py::MethodDef).malloc(function_count + 1)
    definition.value.m_methods = method_table
  end

  # Called by CPython (GIL held) when a capsule's refcount reaches zero.
  def self.unpin_capsule(capsule : Py::Object) : Nil
    pointer = Py.PyCapsule_GetPointer(capsule, eternal_cstr(CAPSULE_NAME))
    unpin(pointer) unless pointer.null?
  rescue exception : Exception
    # Destructors must never raise across the boundary.
    # Raw write(2): touching Crystal's STDERR constant needs
    # Thread.current, which crashes on foreign threads.
    message = cstr("pycr: ignoring error while unpinning: #{exception.class.name}: #{exception.message || "no message"}\n")
    LibC.write(2, message, LibC.strlen(message))
  end
end
