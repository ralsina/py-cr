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
      register_iterator_type
    end

    # --- iteration protocol --------------------------------------------------
    #
    # pyiter methods return a Crystal Iterator; tp_iter wraps it in an
    # IterState (pinned, with the element conversion baked into a
    # closure) held by an instance of this internal iterator type. One
    # generic tp_next serves every class. A separate iterator object
    # per tp_iter call keeps concurrent iterations independent, and the
    # IterState holds a PyRef to the owner so it cannot be deallocated
    # mid-iteration.

    class IterState
      property next_item : -> Py::Object?
      property owner_ref : PyRef?

      def initialize(&@next_item : -> Py::Object?)
        @owner_ref = nil
      end

      def initialize(@next_item : -> Py::Object?, @owner_ref : PyRef?)
      end
    end

    protected def self.iterator_type : Py::Object
      @@iterator_type ||= Pointer(Void).null.as(Py::Object)
    end

    protected def self.iterator_type=(type : Py::Object) : Nil
      @@iterator_type = type
    end

    protected def self.iterator_states : Set(Void*)
      @@iterator_states ||= Set(Void*).new
    end

    # Creates the internal iterator type once and roots it: it is not
    # added to the module, so nothing else holds a reference.
    protected def self.register_iterator_type : Nil
      return unless iterator_type.null?

      slots = Pointer(Py::TypeSlot).malloc(5)
      store_tp_self_iter(slots, 0, PY_TP_ITER)
      store_tp_iternext(slots, 1, PY_TP_ITERNEXT)
      store_tp_dealloc(slots, 2, PY_TP_DEALLOC, ->iterator_dealloc(Py::Object))

      spec = Pointer(Py::TypeSpec).malloc(1)
      spec.value.name = Pycr.cstr("pycr._Iterator")
      spec.value.basicsize = Pycr::INSTANCE_DATA_OFFSET + 8
      spec.value.itemsize = 0
      spec.value.flags = PY_TPFLAGS_DEFAULT
      spec.value.slots = slots

      @@iterator_slots = slots
      @@iterator_spec = spec
      type = Py.PyType_FromSpec(spec)
      if type.null?
        STDERR.puts "pycr: failed to create iterator type\n"
      else
        self.iterator_type = type
      end
    end

    class_property iterator_slots : Py::TypeSlot* = Pointer(Py::TypeSlot).null
    class_property iterator_spec : Py::TypeSpec* = Pointer(Py::TypeSpec).null

    protected def self.iterator_dealloc(instance : Py::Object) : Nil
      pointer = Pycr.instance_data(instance)
      unless pointer.null?
        # Deterministic owner-release: dealloc runs under the GIL at a
        # known point, so the owner wrapper's pin drops now instead of
        # whenever the IterState's PyRef finalizer gets around to it.
        state = pointer.as(IterState)
        owner_ref = state.owner_ref
        owner_ref.release unless owner_ref.nil?
        iterator_states.delete(pointer)
        Pycr.unpin(pointer)
      end
      Py.PyObject_Free(instance)
    end

    # Builds a Python iterator over a Crystal iterator's items. The
    # conversion of each item is baked into the next_item closure by
    # the caller (the pyiter thunk), so this stays non-generic.
    def self.new_iterator(state : IterState, owner : Py::Object) : Py::Object
      state.owner_ref = PyRef.new(owner)
      Pycr.pin(state.as(Void*))
      iterator_states << state.as(Void*)
      instance = Py.PyType_GenericAlloc(iterator_type, 0)
      if instance.null?
        Pycr.unpin(state.as(Void*))
        iterator_states.delete(state.as(Void*))
        return Pointer(Void).null.as(Py::Object)
      end
      (instance.as(UInt8*) + Pycr::INSTANCE_DATA_OFFSET).as(Pointer(Void*)).value = state.as(Void*)
      instance
    end

    # tp_next/tp_iter funs live at global scope below the module.

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
                            klass : Pycr::PyObject.class,
                            methods : Array(MethodEntry),
                            tp_new : (Py::Object, Py::Object, Py::Object) -> Py::Object,
                            tp_dealloc : (Py::Object) -> Nil,
                            tp_repr : ((Py::Object) -> Py::Object)?,
                            tp_str : (Py::Object) -> Py::Object,
                            tp_iter : ((Py::Object) -> Py::Object)?,
                            tp_len : ((Py::Object) -> Int64)?,
                            tp_getitem : ((Py::Object, Py::Object) -> Py::Object)?,
                            tp_setitem : ((Py::Object, Py::Object, Py::Object) -> Int32)?,
                            tp_contains : ((Py::Object, Py::Object) -> Int32)?,
                            tp_compare : ((Py::Object, Py::Object, Int32) -> Py::Object)?,
                            tp_add : ((Py::Object, Py::Object) -> Py::Object)?,
                            tp_sub : ((Py::Object, Py::Object) -> Py::Object)?,
                            tp_mul : ((Py::Object, Py::Object) -> Py::Object)?,
                            getsets : Array(GetSetEntry)) : Nil
      method_table = build_method_table(methods)
      getset_table = build_getset_table(getsets)

      slots = Pointer(Py::TypeSlot).malloc(24)
      store_tp_new(slots, 0, PY_TP_NEW, tp_new)
      store_tp_dealloc(slots, 1, PY_TP_DEALLOC, tp_dealloc)
      store_tp_data(slots, 2, PY_TP_METHODS, method_table.as(Void*))
      next_slot = write_optional_slots(slots, 3, getset_table, getsets, tp_repr,
        tp_iter, tp_len, tp_getitem, tp_setitem, tp_contains, tp_compare,
        tp_add, tp_sub, tp_mul)
      store_tp_unary(slots, next_slot, PY_TP_STR, tp_str)

      spec = Pointer(Py::TypeSpec).malloc(1)
      spec.value.name = Pycr.cstr(python_name)
      spec.value.basicsize = Pycr::INSTANCE_DATA_OFFSET + 8
      spec.value.itemsize = 0
      spec.value.flags = PY_TPFLAGS_DEFAULT
      spec.value.slots = slots

      class_tables[python_name] = {method_table, slots, spec, getset_table}

      type = Py.PyType_FromSpec(spec)
      if type.null?
        Py.Py_DecRef(type) unless type.null?
      else
        # Root the type for factory-style wrap() lookups.
        type_by_class[klass] = type
        # AddObject steals the reference only on success.
        if Py.PyModule_AddObject(module_object, Pycr.cstr(python_name.split('.').last), type) != 0
          Py.Py_DecRef(type) unless type.null?
          type_by_class.delete(klass)
        end
      end
    end

    # Python type objects by Crystal class, rooted here (AddObject's
    # reference belongs to the module; wrap() needs its own lookup).
    def self.type_by_class : Hash(Pycr::PyObject.class, Py::Object)
      @@type_by_class ||= Hash(Pycr::PyObject.class, Py::Object).new
    end

    # Wraps a Crystal instance of a registered exposed class into a
    # Python-owned object (factory functions returning instances).
    def self.wrap(instance : Pycr::PyObject) : Py::Object
      type = type_by_class[instance.class]?
      unless type
        raise ArgumentError.new(
          "#{instance.class} is not an exposed class (no Python type registered)"
        )
      end
      Pycr.pin(instance.as(Void*))
      allocated = Py.PyType_GenericAlloc(type, 0)
      if allocated.null?
        Pycr.unpin(instance.as(Void*))
        return Pointer(Void).null.as(Py::Object)
      end
      (allocated.as(UInt8*) + Pycr::INSTANCE_DATA_OFFSET).as(Pointer(Void*)).value = instance.as(Void*)
      allocated
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

    private def self.build_method_table(methods : Array(MethodEntry)) : Py::MethodDef*
      method_count = methods.size + 1 # plus the all-zero sentinel
      method_table = Pointer(Py::MethodDef).malloc(method_count)
      Slice.new(method_table, method_count).fill(Py::MethodDef.new)
      methods.each_with_index do |(name, implementation), index|
        entry = method_table + index
        entry.value.name = Pycr.cstr(name)
        entry.value.meth = implementation
        entry.value.flags = METH_VARARGS | METH_KEYWORDS
      end
      method_table
    end

    private def self.build_getset_table(getsets : Array(GetSetEntry)) : Py::GetSetDef*
      return Pointer(Py::GetSetDef).null if getsets.empty?
      getset_table = Pointer(Py::GetSetDef).malloc(getsets.size + 1)
      Slice.new(getset_table, getsets.size + 1).fill(Py::GetSetDef.new)
      getsets.each_with_index do |(name, getter, setter), index|
        entry = getset_table + index
        entry.value.name = Pycr.cstr(name)
        entry.value.get = getter
        entry.value.set = setter
      end
      getset_table
    end

    private def self.store_tp_self_iter(slots : Py::TypeSlot*, index : Int32, slot_id : Int32) : Nil
      store_tp_unary(slots, index, slot_id, ->pycr_iterator_iter(Py::Object))
    end

    private def self.store_tp_iternext(slots : Py::TypeSlot*, index : Int32, slot_id : Int32) : Nil
      store_tp_unary(slots, index, slot_id, ->pycr_iterator_next(Py::Object))
    end

    # Writes the optional protocol slots (getset table, repr, iter,
    # len, subscript protocols) and returns the next free slot index.
    private def self.write_optional_slots(slots : Py::TypeSlot*, start : Int32,
                                          getset_table : Py::GetSetDef*, getsets : Array(GetSetEntry),
                                          tp_repr : ((Py::Object) -> Py::Object)?,
                                          tp_iter : ((Py::Object) -> Py::Object)?,
                                          tp_len : ((Py::Object) -> Int64)?,
                                          tp_getitem : ((Py::Object, Py::Object) -> Py::Object)?,
                                          tp_setitem : ((Py::Object, Py::Object, Py::Object) -> Int32)?,
                                          tp_contains : ((Py::Object, Py::Object) -> Int32)?,
                                          tp_compare : ((Py::Object, Py::Object, Int32) -> Py::Object)?,
                                          tp_add : ((Py::Object, Py::Object) -> Py::Object)?,
                                          tp_sub : ((Py::Object, Py::Object) -> Py::Object)?,
                                          tp_mul : ((Py::Object, Py::Object) -> Py::Object)?) : Int32
      next_slot = start
      unless getsets.empty?
        store_tp_data(slots, next_slot, PY_TP_GETSET, getset_table.as(Void*))
        next_slot += 1
      end
      unless tp_repr.nil?
        store_tp_unary(slots, next_slot, PY_TP_REPR, tp_repr)
        next_slot += 1
      end
      unless tp_iter.nil?
        store_tp_unary(slots, next_slot, PY_TP_ITER, tp_iter)
        next_slot += 1
      end
      unless tp_len.nil?
        store_tp_len(slots, next_slot, PY_MP_LENGTH, tp_len)
        next_slot += 1
      end
      unless tp_getitem.nil?
        store_tp_subscript(slots, next_slot, PY_MP_SUBSCRIPT, tp_getitem)
        next_slot += 1
      end
      unless tp_setitem.nil?
        store_tp_ass_subscript(slots, next_slot, PY_MP_ASS_SUBSCRIPT, tp_setitem)
        next_slot += 1
      end
      unless tp_contains.nil?
        store_tp_contains(slots, next_slot, PY_SQ_CONTAINS, tp_contains)
        next_slot += 1
      end
      unless tp_compare.nil?
        store_tp_compare(slots, next_slot, PY_TP_RICHCOMPARE, tp_compare)
        next_slot += 1
      end
      {% for name, constant in {"add" => "PY_NB_ADD", "sub" => "PY_NB_SUBTRACT", "mul" => "PY_NB_MULTIPLY"} %}
      unless tp_{{ name.id }}.nil?
        store_tp_binary(slots, next_slot, {{ constant.id }}, tp_{{ name.id }})
        next_slot += 1
      end
      {% end %}
      next_slot
    end

    private def self.store_tp_subscript(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                        implementation : (Py::Object, Py::Object) -> Py::Object) : Nil
      entry = Py::TypeSlotSubscript.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotSubscript))
    end

    private def self.store_tp_ass_subscript(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                            implementation : (Py::Object, Py::Object, Py::Object) -> Int32) : Nil
      entry = Py::TypeSlotAssSubscript.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotAssSubscript))
    end

    private def self.store_tp_contains(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                       implementation : (Py::Object, Py::Object) -> Int32) : Nil
      entry = Py::TypeSlotContains.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotContains))
    end

    private def self.store_tp_compare(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                      implementation : (Py::Object, Py::Object, Int32) -> Py::Object) : Nil
      entry = Py::TypeSlotCompare.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotCompare))
    end

    private def self.store_tp_binary(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                     implementation : (Py::Object, Py::Object) -> Py::Object) : Nil
      entry = Py::TypeSlotSubscript.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotSubscript))
    end

    private def self.store_tp_len(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                  implementation : (Py::Object) -> Int64) : Nil
      entry = Py::TypeSlotLen.new
      entry.slot = slot_id
      entry.pfunc = implementation
      (slots + index).as(UInt8*).copy_from(pointerof(entry).as(UInt8*), sizeof(Py::TypeSlotLen))
    end

    private def self.store_tp_data(slots : Py::TypeSlot*, index : Int32, slot_id : Int32,
                                   data : Void*) : Nil
      entry = slots + index
      entry.value.slot = slot_id
      entry.value.pfunc = data
    end
  end
end

# tp_next for every pyiter-backed iterator: pulls the next converted
# item from the state closure; null means exhausted (no error set).
fun pycr_iterator_next(self_object : Py::Object) : Py::Object
  Pycr.py_call do
    state = Pycr.instance_data(self_object).as(Pycr::Classes::IterState)
    item = state.next_item.call
    # nil from the closure means exhausted: return null with no error
    # set, which CPython reads as StopIteration.
    next Pointer(Void).null.as(Py::Object) if item.nil?
    item
  end
end

# tp_iter for the iterator type: returns self with a new reference
# (it is its own iterator).
fun pycr_iterator_iter(self_object : Py::Object) : Py::Object
  Py.Py_IncRef(self_object)
  self_object
end
