# Heap-type registration machinery shared by both DSL styles; the
# pyclass macro and the pyinit annotation pass emit calls into this.
#
# A Python-side instance of an exposed class is a plain CPython object
# whose bytes right after the PyObject header hold the pinned Crystal
# object. The pin registry (Pycr.registry) keeps that object alive
# while Python owns it, because Boehm cannot see CPython's heap.

module Pycr
  module Classes
    # Registers exposed classes; called from the fun the pyinit macro
    # generates. Takes bound procs rather than class objects: an
    # Array(Pycr::PyObject.class) would erase the concrete classes and
    # per-class __py_register would not dispatch.
    def self.bootstrap(module_object : Py::Object, exposed : Array(Py::Object -> Nil)) : Nil
      exposed.each &.call(module_object)
    end

    alias MethodEntry = Tuple(String, (Py::Object, Py::Object, Py::Object) -> Py::Object)
    alias Getter = (Py::Object, Void*) -> Py::Object
    alias Setter = (Py::Object, Py::Object, Void*) -> Int32
    alias GetSetEntry = Tuple(String, Getter, Setter)

    # Per-class tables must outlive their types (tp_methods and
    # tp_getset point into them), so they are malloc'd once and rooted
    # in this hash.
    def self.class_tables : Hash(String, Tuple(Py::MethodDef*, Py::TypeSlot*, Py::TypeSpec*, Py::GetSetDef*))
      @@class_tables ||= Hash(String, Tuple(Py::MethodDef*, Py::TypeSlot*, Py::TypeSpec*, Py::GetSetDef*)).new
    end

    def self.register_class(module_object : Py::Object, python_name : String,
                            methods : Array(MethodEntry),
                            tp_new : (Py::Object, Py::Object, Py::Object) -> Py::Object,
                            tp_dealloc : (Py::Object) -> Nil,
                            tp_repr : ((Py::Object) -> Py::Object)?,
                            getsets : Array(GetSetEntry)) : Nil
      method_count = methods.size + 1 # plus the all-zero sentinel
      method_table = Pointer(Py::MethodDef).malloc(method_count)
      Slice.new(method_table, method_count).fill(Py::MethodDef.new)
      methods.each_with_index do |(name, implementation), index|
        entry = method_table + index
        entry.value.name = Pycr.cstr(name)
        entry.value.meth = implementation
        entry.value.flags = METH_VARARGS | METH_KEYWORDS
      end

      getset_table = Pointer(Py::GetSetDef).null
      unless getsets.empty?
        getset_table = Pointer(Py::GetSetDef).malloc(getsets.size + 1)
        Slice.new(getset_table, getsets.size + 1).fill(Py::GetSetDef.new)
        getsets.each_with_index do |(name, getter, setter), index|
          entry = getset_table + index
          entry.value.name = Pycr.cstr(name)
          entry.value.get = getter
          entry.value.set = setter
        end
      end

      # Slots: new, dealloc, methods, then optionally getset and repr,
      # then the all-zero sentinel entry.
      slots = Pointer(Py::TypeSlot).malloc(7)
      store_tp_new(slots, 0, PY_TP_NEW, tp_new)
      store_tp_dealloc(slots, 1, PY_TP_DEALLOC, tp_dealloc)
      store_tp_data(slots, 2, PY_TP_METHODS, method_table.as(Void*))
      next_slot = 3
      unless getsets.empty?
        store_tp_data(slots, next_slot, PY_TP_GETSET, getset_table.as(Void*))
        next_slot += 1
      end
      unless tp_repr.nil?
        store_tp_unary(slots, next_slot, PY_TP_REPR, tp_repr)
      end

      spec = Pointer(Py::TypeSpec).malloc(1)
      spec.value.name = Pycr.cstr(python_name)
      spec.value.basicsize = Pycr::INSTANCE_DATA_OFFSET + 8
      spec.value.itemsize = 0
      spec.value.flags = PY_TPFLAGS_DEFAULT
      spec.value.slots = slots

      class_tables[python_name] = {method_table, slots, spec, getset_table}

      type = Py.PyType_FromSpec(spec)
      if type.null? || Py.PyModule_AddObject(module_object, Pycr.cstr(python_name.split('.').last), type) != 0
        # AddObject steals the reference only on success.
        Py.Py_DecRef(type) unless type.null?
      end
    end

    # TypeSlot.pfunc is a void pointer so the struct mirrors the C
    # layout; the typed helpers write through a same-layout struct
    # with a typed function field, where proc literals convert
    # automatically, then copy the bytes into the slot array.
    private def self.store_tp_new(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                  implementation : (Py::Object, Py::Object, Py::Object) -> Py::Object) : Nil
      entry = Py::TypeSlotNew.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotNew))
    end

    private def self.store_tp_dealloc(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                      implementation : (Py::Object) -> Nil) : Nil
      entry = Py::TypeSlotDealloc.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotDealloc))
    end

    private def self.store_tp_unary(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                    implementation : (Py::Object) -> Py::Object) : Nil
      entry = Py::TypeSlotUnary.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotUnary))
    end

    private def self.store_tp_data(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                   data : Void*) : Nil
      entry = slots + index
      entry.value.slot = slot_id
      entry.value.pfunc = data
    end
  end
end
