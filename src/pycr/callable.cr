# Pycr::Callable: a Python callable (function, lambda, method, class,
# ...) that Crystal code can invoke — and store: the reference is owned
# through Pycr::PyRef, so a Callable kept in a Crystal ivar keeps the
# Python object alive across calls (the old borrowed-only limitation is
# gone; see pyref.cr for the lifetime machinery).

module Pycr
  class Callable
    def initialize(@ref : PyRef)
    end

    def initialize(object : Py::Object)
      @ref = PyRef.new(object)
    end

    # Borrowed view of the wrapped object, for the duration of a call
    # or introspection; the PyRef owns the real reference.
    def object : Py::Object
      @ref.object
    end

    # Deterministic decref (idempotent). Storage can just drop the
    # Callable - the PyRef finalizer decrefs eventually - but code that
    # needs the reference count to drop at a known point releases.
    def release : Nil
      @ref.release
    end

    # Calls the callable, converting every argument through
    # Pycr::Conversions.to_python. Returns the raw result object;
    # convert it with Pycr::Conversions.from_python. If the callable
    # raises, the Python error indicator is already set and
    # PythonError propagates to the boundary untouched, so Python sees
    # its own exception.
    def call(*arguments : *T) : Py::Object forall T
      tuple = Py.PyTuple_New(arguments.size)
      {% for index in 0...T.size %}
        # SetItem steals the reference to the converted argument.
        Py.PyTuple_SetItem(tuple, {{ index }}, Pycr::Conversions.to_python(arguments[{{ index }}]))
      {% end %}
      result = Py.PyObject_Call(@ref.object, tuple, Pointer(Void).null.as(Py::Object))
      Py.Py_DecRef(tuple)
      if result.null?
        raise PythonError.new("call to the Python callable failed")
      end
      result
    end
  end
end
