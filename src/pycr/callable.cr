# Pycr::Callable: a Python callable (function, lambda, method, class,
# ...) that Crystal code can invoke.

module Pycr
  class Callable
    # The wrapped object is BORROWED: it stays alive because the
    # argument tuple of the extension call that received it is alive
    # for the duration of the call. Do not store a Callable beyond the
    # call that produced it; that needs owned references, which the
    # framework does not manage yet.
    def initialize(@object : Py::Object)
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
      result = Py.PyObject_Call(@object, tuple, Pointer(Void).null.as(Py::Object))
      Py.Py_DecRef(tuple)
      if result.null?
        raise PythonError.new("call to the Python callable failed")
      end
      result
    end
  end
end
