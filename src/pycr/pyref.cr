# PyRef: an owned reference to a Python object that Crystal code can
# store. This is the bridge between the two memory systems:
#
#   - creating a PyRef increfs the Python object, making the reference
#     visible to CPython's cycle collector (it will not free the object
#     while the invisible Crystal side may still use it)
#   - the PyRef is a normal Boehm-allocated Crystal object; a Boehm
#     finalizer registered on it decrefs the Python object when the
#     PyRef becomes unreachable, so storage needs no manual release
#     (Crystal has no destructors; Boehm finalizers are the closest
#     equivalent)
#
# Timing: the finalizer runs at some collection AFTER the PyRef (and
# its owners) became unreachable - Boehm's conservative stack scanning
# can delay that by a cycle or two, and safe_collect drains the
# finalizer queue synchronously. Code that needs the decref to happen
# at a known point calls release explicitly (idempotent); the
# finalizer is the safety net for the store-and-forget case.
#
# The finalizer acquires the GIL around the decref via PyGILState:
# our collection policy guarantees GC.collect runs at GIL-held
# boundary points, but libgc may also drain finalizers on its own
# thread, and PyGILState_Ensure is safe in both cases (it is nestable
# on the thread already holding the GIL).

lib Py
  fun PyGILState_Ensure : Int32
  fun PyGILState_Release(state : Int32)
end

# Runs when a PyRef is collected. The client-data pointer is the
# PyRef's indirection cell (holding the current Py::Object, or null
# after an explicit release), so this needs no closure (finalizer
# procs must be C-callable, capture-free).
fun pyref_finalize(_pyref : Void*, client_data : Void*)
  cell = client_data.as(Pointer(Void*))
  object = cell.value
  unless object.null?
    cell.value = Pointer(Void).null
    state = Py.PyGILState_Ensure
    Py.Py_DecRef(object.as(Py::Object))
    Py.PyGILState_Release(state)
  end
  Pycr.note_pyref_finalized
end

module Pycr
  class PyRef
    # Introspection for the notes: whether the last finalizer ran on
    # the bootstrap thread (-1 unknown, 0 no, 1 yes).
    @@finalizer_same_thread = Atomic(Int32).new(-1)
    @@bootstrap_thread : LibC::PthreadT = LibC.pthread_self

    def self.last_finalizer_same_thread : Int32
      @@finalizer_same_thread.get
    end

    def self.note_finalized : Nil
      @@finalizer_same_thread.set(LibC.pthread_self == @@bootstrap_thread ? 1 : 0)
    end

    getter object : Py::Object

    @cell : Pointer(Void*)

    def initialize(object : Py::Object)
      @object = object
      Py.Py_IncRef(@object)
      # The finalizer reads through this cell so an explicit release
      # can null it and make the eventual finalizer a no-op.
      @cell = Pointer(Void*).malloc(1)
      @cell.value = object
      LibGC.register_finalizer(
        self.as(Void*),
        ->pyref_finalize(Void*, Void*),
        @cell.as(Void*),
        Pointer(LibGC::Finalizer).null,
        Pointer(Pointer(Void)).null
      )
    end

    # Releases the reference now: decrefs immediately and makes the
    # eventual finalizer a no-op. Idempotent.
    def release : Nil
      object = @object
      return if object.null?
      @object = Pointer(Void).null.as(Py::Object)
      @cell.value = Pointer(Void).null
      Py.Py_DecRef(object)
    end
  end

  def self.note_pyref_finalized : Nil
    PyRef.note_finalized
  end
end
