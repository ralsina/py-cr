# Typed conversions between Crystal values and CPython objects.
#
# to_python accepts a Crystal value and returns a new (owned) reference;
# from_python accepts a borrowed reference plus the target type and
# returns a Crystal value, raising PythonError when the object does not
# convert (the Python error indicator is already set at that point, so
# the caller must let py_call pass it through).

module Pycr
  module Conversions
    def self.to_python(value : String) : Py::Object
      Py.PyUnicode_FromString(Pycr.cstr(value))
    end

    def self.to_python(value : Bool) : Py::Object
      Py.PyBool_FromLong(value ? 1 : 0)
    end

    def self.to_python(value : Int32) : Py::Object
      Py.PyLong_FromLongLong(value)
    end

    def self.to_python(value : Int64) : Py::Object
      Py.PyLong_FromLongLong(value)
    end

    def self.to_python(value : Float64) : Py::Object
      Py.PyFloat_FromDouble(value)
    end

    def self.to_python(value : Nil) : Py::Object
      # Py_None is a macro over a data symbol, so build it instead.
      Py.Py_BuildValue(Pycr.cstr(""))
    end

    def self.to_python(value : Bytes) : Py::Object
      Py.PyBytes_FromStringAndSize(value.to_unsafe, value.size)
    end

    # Escape hatch: a raw CPython object passes through unchanged. The
    # value must be an owned reference going in (to_python gives it
    # away) and borrowed coming out (from_python).
    def self.to_python(value : Py::Object) : Py::Object
      value
    end

    def self.to_python(value : Array(T)) : Py::Object forall T
      Pycr.note_allocation(value.size * 8)
      list = Py.PyList_New(value.size)
      value.each_with_index do |item, index|
        # SetItem steals the reference to the converted item.
        Py.PyList_SetItem(list, index, to_python(item))
      end
      list
    end

    # NamedTuple converts to a dict: names become string keys, values
    # convert recursively. Names exist only at compile time, so the
    # members are enumerated in macro space via the double-splat
    # implementation below.
    def self.to_python(value : NamedTuple) : Py::Object
      to_python_named(**value)
    end

    private def self.to_python_named(**value : **T) : Py::Object forall T
      {% begin %}
        dict = Py.PyDict_New
        {% for key in T.keys %}
          pycr_key = to_python({{ key.stringify }})
          pycr_item = to_python(value[{{ key.symbolize }}])
          if Py.PyDict_SetItem(dict, pycr_key, pycr_item) == -1
            Py.Py_DecRef(pycr_key)
            Py.Py_DecRef(pycr_item)
            Py.Py_DecRef(dict)
            raise PythonError.new("failed to insert {{ key }} into dict")
          end
          # SetItem took its own reference; drop ours.
          Py.Py_DecRef(pycr_key)
          Py.Py_DecRef(pycr_item)
        {% end %}
        dict
      {% end %}
    end

    def self.to_python(value : Tuple(*T)) : Py::Object forall T
      tuple = Py.PyTuple_New({{ T.size }})
      {% for index in 0...T.size %}
        # SetItem steals the reference to the converted element.
        Py.PyTuple_SetItem(tuple, {{ index }}, to_python(value[{{ index }}]))
      {% end %}
      tuple
    end

    def self.to_python(value : Hash(K, V)) : Py::Object forall K, V
      dict = Py.PyDict_New
      value.each do |key, item|
        key_object = to_python(key)
        item_object = to_python(item)
        if Py.PyDict_SetItem(dict, key_object, item_object) == -1
          Py.Py_DecRef(key_object)
          Py.Py_DecRef(item_object)
          Py.Py_DecRef(dict)
          raise PythonError.new("failed to insert into dict")
        end
        Py.Py_DecRef(key_object)
        Py.Py_DecRef(item_object)
      end
      dict
    end

    def self.from_python(obj : Py::Object, type : String.class) : String
      size = 0_i64
      pointer = Py.PyUnicode_AsUTF8AndSize(obj, pointerof(size))
      raise PythonError.new("expected a str") if pointer.null?
      Pycr.note_allocation(size.to_i64)
      String.new(pointer, size.to_i32)
    end

    # Escape hatch: see to_python(Py::Object).
    def self.from_python(obj : Py::Object, type : Py::Object.class) : Py::Object
      obj
    end

    def self.from_python(obj : Py::Object, type : Bytes.class) : Bytes
      buffer = Pointer(UInt8).null
      size = 0_i64
      if Py.PyBytes_AsStringAndSize(obj, pointerof(buffer), pointerof(size)) != 0
        # AsStringAndSize set TypeError for non-bytes already.
        raise PythonError.new("expected bytes")
      end
      # buffer is owned by obj; copy so the result outlives the call.
      copy = Bytes.new(size)
      copy.copy_from(Bytes.new(buffer, size))
      copy
    end

    def self.from_python(obj : Py::Object, type : Callable.class) : Callable
      if Py.PyCallable_Check(obj) == 0
        raise TypeCastError.new("expected a callable")
      end
      Callable.new(obj)
    end

    # Owning reference: increfs via PyRef, decref happens when the
    # PyRef is collected (see pyref.cr).
    def self.from_python(obj : Py::Object, type : PyRef.class) : PyRef
      PyRef.new(obj)
    end

    # Returns an owned view: the PyRef keeps its own reference, this
    # increfs for the recipient. Refcount-correct even if the PyRef is
    # collected afterwards.
    def self.to_python(value : PyRef) : Py::Object
      Py.Py_IncRef(value.object)
      value.object
    end

    def self.from_python(obj : Py::Object, type : Bool.class) : Bool
      result = Py.PyObject_IsTrue(obj)
      raise PythonError.new("expected a bool-like value") if result == -1
      result == 1
    end

    def self.from_python(obj : Py::Object, type : Int64.class) : Int64
      result = Py.PyLong_AsLongLong(obj)
      if result == -1 && !Py.PyErr_Occurred.null?
        raise PythonError.new("expected an int")
      end
      result
    end

    def self.from_python(obj : Py::Object, type : Int32.class) : Int32
      result = from_python(obj, Int64)
      if result < Int32::MIN || result > Int32::MAX
        raise ArgumentError.new("integer #{result} does not fit in an Int32")
      end
      result.to_i32
    end

    def self.from_python(obj : Py::Object, type : Float64.class) : Float64
      result = Py.PyFloat_AsDouble(obj)
      if result == -1.0 && !Py.PyErr_Occurred.null?
        raise PythonError.new("expected a number")
      end
      result
    end

    def self.from_python(obj : Py::Object, type : Hash(K, V).class) : Hash(K, V) forall K, V
      size = Py.PyDict_Size(obj)
      if size < 0
        # PyDict_Size on a non-dict sets SystemError, not TypeError.
        Py.PyErr_Clear
        raise TypeCastError.new("expected a dict")
      end
      result = Hash(K, V).new
      position = 0_i64
      key_object = Pointer(Void).null.as(Py::Object)
      value_object = Pointer(Void).null.as(Py::Object)
      while Py.PyDict_Next(obj, pointerof(position), pointerof(key_object), pointerof(value_object)) != 0
        # key/value are borrowed references; obj keeps them alive.
        result[from_python(key_object, K)] = from_python(value_object, V)
      end
      result
    end

    def self.from_python(obj : Py::Object, type : Array(T).class) : Array(T) forall T
      size = Py.PyList_Size(obj)
      if size < 0
        # PyList_Size on a non-list sets SystemError, not TypeError.
        Py.PyErr_Clear
        raise TypeCastError.new("expected a list")
      end
      Pycr.note_allocation(size * 8)
      result = Array(T).new(size)
      size.times do |index|
        # GetItem returns a borrowed reference; obj keeps it alive.
        item = Py.PyList_GetItem(obj, index)
        result << from_python(item, T)
      end
      result
    end
  end
end
