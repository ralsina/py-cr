# The py-cr DSL: two ways to declare what Python sees.
#
# Module-level entry point (generates the PyInit_<name> fun):
#
#   Pycr.pyinit "mymodule" do
#     Pycr.pyfunction def greet(name : String) : String
#       "Hello, #{name}!"
#     end
#   end
#
# Classes, block style:
#
#   Pycr.pyclass Counter, "mymodule.Counter" do
#     pynew def initialize(count : Int32 = 0)
#       @count = count
#     end
#
#     pymethod def increment(amount : Int32 = 1) : Int32
#       @count += amount
#     end
#
#     pyattr count : Int32
#
#     pyrepr def describe : String
#       "Counter(count=#{@count})"
#     end
#   end
#
# Classes, annotation style (PyO3-like; every declared argument can
# also be passed as a keyword argument, in both styles):
#
#   @[Pycr::PyClass("mymodule.Greeter")]
#   class Greeter < Pycr::PyObject
#     @[Pycr::PyNew]
#     def initialize(greetings : Int32 = 0)
#       @greetings = greetings
#     end
#
#     @[Pycr::PyMethod]
#     def greet(word : String = "hi") : Int32
#       @greetings += 1
#     end
#
#     @[Pycr::PyAttr]
#     def greetings : Int32
#       @greetings
#     end
#
#     @[Pycr::PyRepr]
#     def describe : String
#       "Greeter(#@greetings)"
#     end
#   end
#
# pyinit discovers every subclass of Pycr::PyObject (both styles) at
# compile time and registers it; there are no class lists to maintain.
# Calls directly inside the pyinit block must be qualified
# (Pycr.pyfunction ...) because the generated code expands at the top
# level; calls inside a pyclass block are inspected, not expanded, so
# they stay bare.
#
# Both pyfunction and pymethod accept an optional Python-side name
# override as their first argument: Pycr.pyfunction "is_big", def big?(...).
#
# NOTE: the argument-parsing emission below appears many times (pynew,
# pymethod, pyfunction and their annotation-style variants). It cannot
# be factored into a helper macro: passing the Def node as a macro
# argument re-emits it as a def in a position where Crystal forbids
# nested defs. The copies must stay in sync.

module Pycr
  # Annotations for the annotation style; see pyinit.
  annotation PyClass
  end

  annotation PyNew
  end

  annotation PyMethod
  end

  annotation PyRepr
  end

  annotation PyAttr
  end

  annotation PyIter
  end

  annotation PyGetItem
  end

  annotation PySetItem
  end

  annotation PyContains
  end

  annotation PyCompare
  end

  annotation PyAdd
  end

  annotation PySub
  end

  annotation PyMul
  end

  annotation PyLen
  end

  macro pyclass(klass, python_name, &block)
    {% nodes = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
    class {{ klass.id }} < Pycr::PyObject
      {% has_repr = false %}
      {% has_attrs = false %}
      {% has_iter = false %}
      {% has_len = false %}
      {% has_getitem = false %}
      {% has_setitem = false %}
      {% has_contains = false %}
      {% has_getter = false %}
      {% has_compare = false %}
      {% has_add = false %}
      {% has_sub = false %}
      {% has_mul = false %}
      {% for node in nodes %}
        {% if node.class_name == "Call" && node.name == :pyattr %}
          {% has_attrs = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pyiter %}
          {% has_iter = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pylen %}
          {% has_len = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pygetitem %}
          {% has_getitem = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pysetitem %}
          {% has_setitem = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pycontains %}
          {% has_contains = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pygetter %}
          {% has_getter = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pycompare %}
          {% has_compare = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pyadd %}
          {% has_add = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pysub %}
          {% has_sub = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pymul %}
          {% has_mul = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pynew %}
          {% init_def = node.args[0] %}
          {{ init_def }}

          def self.__py_new(subtype : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
            Pycr.py_call do
              {% format_string = "" %}
              {% for arg in init_def.args %}
                {% if !arg.default_value.nil? && !format_string.includes?("|") %}
                  {% format_string = format_string + "|" %}
                {% end %}
                {% format_string = format_string + "O" %}
              {% end %}
              {% if format_string == "" %}
                raise TypeCastError.new({{ klass.id.stringify }} + ".new() takes no arguments") unless kwargs.null? || Py.PyDict_Size(kwargs) == 0
                Pycr.py_wrap({{ klass.id }}.new, subtype)
              {% else %}
                {% for arg in init_def.args %}
                  py_arg_{{ arg.name }} = Pointer(Void).null.as(Py::Object)
                {% end %}
                if Py.PyArg_ParseTupleAndKeywords(args, kwargs, Pycr.cstr({{ format_string }}), Pycr.kwlist({{ klass.id.stringify }} + ".__new__", [{% for arg in init_def.args %}"{{ arg.name }}", {% end %}]){% for arg in init_def.args %}, pointerof(py_arg_{{ arg.name }}){% end %}) == 0
                  next Pointer(Void).null.as(Py::Object)
                end
                {% for arg in init_def.args %}
                  {% if !arg.default_value.nil? %}
                    {{ arg.name }} = py_arg_{{ arg.name }}.null? ? ({{ arg.default_value }}).as({{ arg.restriction }}) : Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                  {% else %}
                    {{ arg.name }} = Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                  {% end %}
                {% end %}
                Pycr.py_wrap({{ klass.id }}.new({% for arg in init_def.args %}{{ arg.name }}, {% end %}), subtype)
              {% end %}
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pymethod %}
          {% if node.args[0].class_name == "Def" %}
            {% method_def = node.args[0] %}
            {% method_python_name = method_def.name %}
          {% else %}
            {% method_python_name = node.args[0].name %}
            {% method_def = node.args[1] %}
          {% end %}
          {{ method_def }}

          def self.__pymethod_{{ method_def.name }}(self_object : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              {% format_string = "" %}
              {% for arg in method_def.args %}
                {% if !arg.default_value.nil? && !format_string.includes?("|") %}
                  {% format_string = format_string + "|" %}
                {% end %}
                {% format_string = format_string + "O" %}
              {% end %}
              {% if format_string == "" %}
                raise TypeCastError.new("{{ method_python_name }}() takes no keyword arguments") unless kwargs.null? || Py.PyDict_Size(kwargs) == 0
                Pycr::Conversions.to_python(pycr_receiver.{{ method_def.name }})
              {% else %}
                {% for arg in method_def.args %}
                  py_arg_{{ arg.name }} = Pointer(Void).null.as(Py::Object)
                {% end %}
                if Py.PyArg_ParseTupleAndKeywords(args, kwargs, Pycr.cstr({{ format_string }}), Pycr.kwlist({{ klass.id.stringify }} + ".{{ method_python_name }}", [{% for arg in method_def.args %}"{{ arg.name }}", {% end %}]){% for arg in method_def.args %}, pointerof(py_arg_{{ arg.name }}){% end %}) == 0
                  next Pointer(Void).null.as(Py::Object)
                end
                {% for arg in method_def.args %}
                  {% if !arg.default_value.nil? %}
                    {{ arg.name }} = py_arg_{{ arg.name }}.null? ? ({{ arg.default_value }}).as({{ arg.restriction }}) : Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                  {% else %}
                    {{ arg.name }} = Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                  {% end %}
                {% end %}
                Pycr::Conversions.to_python(pycr_receiver.{{ method_def.name }}({% for arg in method_def.args %}{{ arg.name }}, {% end %}))
              {% end %}
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pyiter %}
          {% iter_def = node.args[0] %}
          {{ iter_def }}

          def self.__py_iter(self_object : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              pycr_iterator = pycr_receiver.{{ iter_def.name }}
              pycr_state = Pycr::Classes::IterState.new do
                pycr_item = pycr_iterator.next
                if pycr_item.is_a?(Iterator::Stop)
                  nil
                else
                  pycr_converted = Pycr::Conversions.to_python(pycr_item)
                  raise Pycr::PythonError.new("failed to convert iteration item") if pycr_converted.null?
                  pycr_converted
                end
              end
              Pycr::Classes.new_iterator(pycr_state, self_object)
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pylen %}
          {% len_def = node.args[0] %}
          {{ len_def }}

          def self.__py_len(self_object : Py::Object) : Int64
            Pycr.py_call_int64 do
              Pycr.instance_data(self_object).as({{ klass.id }}).{{ len_def.name }}.to_i64
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pygetitem %}
          {% getitem_def = node.args[0] %}
          {% raise "pygetitem requires exactly one key argument" if getitem_def.args.size != 1 %}
          {{ getitem_def }}

          def self.__py_getitem(self_object : Py::Object, key_object : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              {% getitem_key = getitem_def.args[0].restriction.stringify %}
              {% if getitem_key == "Int32" || getitem_key == "Int64" %}
                {% len_name = nil %}
                {% for n in nodes %}
                  {% if n.class_name == "Call" && n.name == :pylen %}
                    {% len_name = n.args[0].name %}
                  {% end %}
                {% end %}
                {% if len_name %}
                  pycr_bounds = Pycr.unpack_slice(key_object, pycr_receiver.{{ len_name }}.to_i64)
                  unless pycr_bounds.nil?
                    pycr_start, pycr_stop, pycr_step, pycr_count = pycr_bounds
                    pycr_result = Py.PyList_New(pycr_count)
                    pycr_index = pycr_start
                    pycr_i = 0_i64
                    while pycr_i < pycr_count
                      Py.PyList_SetItem(pycr_result, pycr_i, Pycr::Conversions.to_python(pycr_receiver.{{ getitem_def.name }}(
                        {% if getitem_key == "Int32" %}
                          pycr_index.to_i32
                        {% else %}
                          pycr_index
                        {% end %}
                      )))
                      pycr_index += pycr_step
                      pycr_i += 1
                    end
                    next pycr_result
                  end
                {% end %}
              {% end %}
              pycr_key = Pycr::Conversions.from_python(key_object, {{ getitem_def.args[0].restriction }})
              Pycr::Conversions.to_python(pycr_receiver.{{ getitem_def.name }}(pycr_key))
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pysetitem %}
          {% setitem_def = node.args[0] %}
          {% raise "pysetitem requires exactly key and value arguments" if setitem_def.args.size != 2 %}
          {{ setitem_def }}

          def self.__py_setitem(self_object : Py::Object, key_object : Py::Object, value_object : Py::Object) : Int32
            Pycr.py_call_int do
              raise NotImplementedError.new("deletion is not supported") if value_object.null?
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              pycr_key = Pycr::Conversions.from_python(key_object, {{ setitem_def.args[0].restriction }})
              pycr_value = Pycr::Conversions.from_python(value_object, {{ setitem_def.args[1].restriction }})
              pycr_receiver.{{ setitem_def.name }}(pycr_key, pycr_value)
              0
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pycontains %}
          {% contains_def = node.args[0] %}
          {% raise "pycontains requires exactly one argument" if contains_def.args.size != 1 %}
          {{ contains_def }}

          def self.__py_contains(self_object : Py::Object, key_object : Py::Object) : Int32
            Pycr.py_call_int do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              pycr_key = Pycr::Conversions.from_python(key_object, {{ contains_def.args[0].restriction }})
              pycr_receiver.{{ contains_def.name }}(pycr_key) ? 1 : 0
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pygetter %}
          {% getter_def = node.args[0] %}
          {{ getter_def }}

          def self.__pygetter_get_{{ getter_def.name }}(self_object : Py::Object, _closure : Void*) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              Pycr::Conversions.to_python(pycr_receiver.{{ getter_def.name }})
            end
          end

          def self.__pygetter_set_{{ getter_def.name }}(self_object : Py::Object, _value : Py::Object, _closure : Void*) : Int32
            Pycr.py_call_int do
              raise NotImplementedError.new("attribute {{ getter_def.name }} is read-only")
              0
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pycompare %}
          {% compare_def = node.args[0] %}
          {% raise "pycompare requires (other : T, op : Int32)" if compare_def.args.size != 2 %}
          {{ compare_def }}

          def self.__py_compare(self_object : Py::Object, other_object : Py::Object, op : Int32) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              begin
                pycr_other = Pycr::Conversions.from_python_unwrapped(other_object, {{ compare_def.args[0].restriction }}).as({{ compare_def.args[0].restriction }})
              rescue TypeCastError
                # incompatible type: NotImplemented lets Python fall back
                Py.Py_IncRef(Pycr.not_implemented)
                next Pycr.not_implemented
              end
              Pycr::Conversions.to_python(pycr_receiver.{{ compare_def.name }}(pycr_other, op))
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pyadd %}
          {% add_def = node.args[0] %}
          {{ add_def }}

          def self.__py_add(self_object : Py::Object, other_object : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              begin
                pycr_other = Pycr::Conversions.from_python_unwrapped(other_object, {{ add_def.args[0].restriction }}).as({{ add_def.args[0].restriction }})
              rescue TypeCastError
                Py.Py_IncRef(Pycr.not_implemented)
                next Pycr.not_implemented
              end
              Pycr::Conversions.to_python(pycr_receiver.{{ add_def.name }}(pycr_other))
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pysub %}
          {% sub_def = node.args[0] %}
          {{ sub_def }}

          def self.__py_sub(self_object : Py::Object, other_object : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              begin
                pycr_other = Pycr::Conversions.from_python_unwrapped(other_object, {{ sub_def.args[0].restriction }}).as({{ sub_def.args[0].restriction }})
              rescue TypeCastError
                Py.Py_IncRef(Pycr.not_implemented)
                next Pycr.not_implemented
              end
              Pycr::Conversions.to_python(pycr_receiver.{{ sub_def.name }}(pycr_other))
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pymul %}
          {% mul_def = node.args[0] %}
          {{ mul_def }}

          def self.__py_mul(self_object : Py::Object, other_object : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
              begin
                pycr_other = Pycr::Conversions.from_python_unwrapped(other_object, {{ mul_def.args[0].restriction }}).as({{ mul_def.args[0].restriction }})
              rescue TypeCastError
                Py.Py_IncRef(Pycr.not_implemented)
                next Pycr.not_implemented
              end
              Pycr::Conversions.to_python(pycr_receiver.{{ mul_def.name }}(pycr_other))
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pyrepr %}
          {% repr_arg = node.args[0] %}
          {% if repr_arg.class_name == "Def" %}
            {{ repr_arg }}
            {% repr_name = repr_arg.name %}
          {% else %}
            {% repr_name = repr_arg.name %}
          {% end %}
          {% has_repr = true %}
          def self.__py_repr(instance : Py::Object) : Py::Object
            Pycr.py_call do
              pycr_receiver = Pycr.instance_data(instance).as({{ klass.id }})
              Pycr::Conversions.to_python(pycr_receiver.{{ repr_name.id }})
            end
          end
        {% elsif node.class_name == "Call" && node.name == :pyattr %}
          {% for attr in node.args %}
            {% attr_name = attr.class_name == "TypeDeclaration" ? attr.var : attr.name %}
            {% attr_type = attr.class_name == "TypeDeclaration" ? attr.type : attr.restriction %}
            property {{ attr_name }} : {{ attr_type }}

            def self.__pyattr_get_{{ attr_name }}(self_object : Py::Object, _closure : Void*) : Py::Object
              Pycr.py_call do
                Pycr::Conversions.to_python(Pycr.instance_data(self_object).as({{ klass.id }}).{{ attr_name }})
              end
            end

            def self.__pyattr_set_{{ attr_name }}(self_object : Py::Object, value : Py::Object, _closure : Void*) : Int32
              Pycr.py_call_int do
                if value.null?
                  raise NotImplementedError.new("cannot delete attribute {{ attr_name }}")
                end
                Pycr.instance_data(self_object).as({{ klass.id }}).{{ attr_name }} = Pycr::Conversions.from_python(value, {{ attr_type }})
                0
              end
            end
          {% end %}
        {% end %}
      {% end %}

      # str() is always wired to to_s: Object#to_s gives the class
      # name by default, better than CPython's <module.Type at 0x...>.
      def self.__py_str(instance : Py::Object) : Py::Object
        Pycr.py_call do
          pycr_receiver = Pycr.instance_data(instance).as({{ klass.id }})
          Pycr::Conversions.to_python(pycr_receiver.to_s)
        end
      end

      def self.__py_register(module_object : Py::Object) : Nil
        Pycr::Classes.register_class(
          module_object,
          {{ python_name }},
          self,
          [
            {% for node in nodes %}
              {% if node.class_name == "Call" && node.name == :pymethod %}
                {% if node.args[0].class_name == "Def" %}
                  {% reg_name = node.args[0].name %}
                  {% reg_thunk = node.args[0].name %}
                {% else %}
                  {% reg_name = node.args[0].name %}
                  {% reg_thunk = node.args[1].name %}
                {% end %}
                {"{{ reg_name }}", ->__pymethod_{{ reg_thunk }}(Py::Object, Py::Object, Py::Object)},
              {% end %}
            {% end %}
          ],
          ->__py_new(Py::Object, Py::Object, Py::Object),
          ->Pycr::PyObject.py_dealloc(Py::Object),
          {% if has_repr %}
            ->__py_repr(Py::Object),
          {% else %}
            nil,
          {% end %}
          ->__py_str(Py::Object),
          {% if has_iter %}
            ->__py_iter(Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_len %}
            ->__py_len(Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_getitem %}
            ->__py_getitem(Py::Object, Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_setitem %}
            ->__py_setitem(Py::Object, Py::Object, Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_contains %}
            ->__py_contains(Py::Object, Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_compare %}
            ->__py_compare(Py::Object, Py::Object, Int32),
          {% else %}
            nil,
          {% end %}
          {% if has_add %}
            ->__py_add(Py::Object, Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_sub %}
            ->__py_sub(Py::Object, Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_mul %}
            ->__py_mul(Py::Object, Py::Object),
          {% else %}
            nil,
          {% end %}
          {% if has_attrs || has_getter %}
            [
              {% for node in nodes %}
                {% if node.class_name == "Call" && node.name == :pyattr %}
                  {% for attr in node.args %}
                    {% attr_name = attr.class_name == "TypeDeclaration" ? attr.var : attr.name %}
                    {"{{ attr_name }}", ->__pyattr_get_{{ attr_name }}(Py::Object, Void*), ->__pyattr_set_{{ attr_name }}(Py::Object, Py::Object, Void*)},
                  {% end %}
                {% end %}
                {% if node.class_name == "Call" && node.name == :pygetter %}
                  {"{{ node.args[0].name }}", ->__pygetter_get_{{ node.args[0].name }}(Py::Object, Void*), ->__pygetter_set_{{ node.args[0].name }}(Py::Object, Py::Object, Void*)},
                {% end %}
              {% end %}
            ]
          {% else %}
            [] of Pycr::Classes::GetSetEntry
          {% end %}
        )
      end
    end
  end

  macro pyinit(module_name, &block)
    {% nodes = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
    {% function_count = 0 %}
    {% block_classes = [] of Nil %}
    {% for node in nodes %}
      {% if node.class_name == "Call" && node.name == :pyclass %}
        {% block_classes = block_classes + [node.args[0]] %}
        {{ node }}
      {% elsif node.class_name == "Call" && node.name == :pyfunction %}
        {% if node.args[0].class_name == "Def" %}
          {% fun_def = node.args[0] %}
          {% python_name = fun_def.name %}
        {% else %}
          {% python_name = node.args[0].name %}
          {% fun_def = node.args[1] %}
        {% end %}
        {{ fun_def }}

        def __pyfunction_{{ fun_def.name }}(_module_self : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
          Pycr.py_call do
            {% format_string = "" %}
            {% for arg in fun_def.args %}
              {% if !arg.default_value.nil? && !format_string.includes?("|") %}
                {% format_string = format_string + "|" %}
              {% end %}
              {% format_string = format_string + "O" %}
            {% end %}
            {% if format_string == "" %}
              raise TypeCastError.new("{{ python_name }}() takes no keyword arguments") unless kwargs.null? || Py.PyDict_Size(kwargs) == 0
              Pycr::Conversions.to_python({{ fun_def.name }})
            {% else %}
              {% for arg in fun_def.args %}
                py_arg_{{ arg.name }} = Pointer(Void).null.as(Py::Object)
              {% end %}
              if Py.PyArg_ParseTupleAndKeywords(args, kwargs, Pycr.cstr({{ format_string }}), Pycr.kwlist({{ module_name }} + ".{{ python_name }}", [{% for arg in fun_def.args %}"{{ arg.name }}", {% end %}]){% for arg in fun_def.args %}, pointerof(py_arg_{{ arg.name }}){% end %}) == 0
                next Pointer(Void).null.as(Py::Object)
              end
              {% for arg in fun_def.args %}
                {% if !arg.default_value.nil? %}
                  {{ arg.name }} = py_arg_{{ arg.name }}.null? ? ({{ arg.default_value }}).as({{ arg.restriction }}) : Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                {% else %}
                  {{ arg.name }} = Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                {% end %}
              {% end %}
              Pycr::Conversions.to_python({{ fun_def.name }}({% for arg in fun_def.args %}{{ arg.name }}, {% end %}))
            {% end %}
          end
        end
        {% function_count = function_count + 1 %}
      {% end %}
    {% end %}

    # Annotation-style classes: generate thunks and __py_register for
    # every Pycr::PyObject subclass carrying a @[Pycr::PyClass]
    # annotation (block-style classes already have their own).
    {% for exposed in Pycr::PyObject.all_subclasses %}
      {% if exposed.annotation(Pycr::PyClass) %}
        {% klass = exposed %}
        {% class_name = exposed.annotation(Pycr::PyClass).args[0] %}
        {% init_def = nil %}
        {% has_repr = false %}
        {% has_attrs = false %}
        {% init_def = nil %}
        {% has_repr = false %}
        {% has_attrs = false %}
        {% has_iter = false %}
        {% has_len = false %}
        {% has_getitem = false %}
        {% has_setitem = false %}
        {% has_contains = false %}
        {% has_compare = false %}
        {% has_add = false %}
        {% has_sub = false %}
        {% has_mul = false %}
        {% for method in klass.methods %}
          {% if method.name == :initialize && method.annotation(Pycr::PyNew) %}
            {% init_def = method %}
          {% end %}
          {% if method.annotation(Pycr::PyRepr) %}
            {% has_repr = true %}
          {% end %}
          {% if method.annotation(Pycr::PyAttr) %}
            {% has_attrs = true %}
          {% end %}
          {% if method.annotation(Pycr::PyIter) %}
            {% has_iter = true %}
          {% end %}
          {% if method.annotation(Pycr::PyLen) %}
            {% has_len = true %}
          {% end %}
          {% if method.annotation(Pycr::PyGetItem) %}
            {% has_getitem = true %}
          {% end %}
          {% if method.annotation(Pycr::PySetItem) %}
            {% has_setitem = true %}
          {% end %}
          {% if method.annotation(Pycr::PyContains) %}
            {% has_contains = true %}
          {% end %}
          {% if method.annotation(Pycr::PyCompare) %}
            {% has_compare = true %}
          {% end %}
          {% if method.annotation(Pycr::PyAdd) %}
            {% has_add = true %}
          {% end %}
          {% if method.annotation(Pycr::PySub) %}
            {% has_sub = true %}
          {% end %}
          {% if method.annotation(Pycr::PyMul) %}
            {% has_mul = true %}
          {% end %}
        {% end %}
        {% if init_def %}
          class {{ klass.id }}
            def self.__py_new(subtype : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
              Pycr.py_call do
                {% format_string = "" %}
                {% for arg in init_def.args %}
                  {% if !arg.default_value.nil? && !format_string.includes?("|") %}
                    {% format_string = format_string + "|" %}
                  {% end %}
                  {% format_string = format_string + "O" %}
                {% end %}
                {% if format_string == "" %}
                  raise TypeCastError.new({{ klass.id.stringify }} + ".new() takes no arguments") unless kwargs.null? || Py.PyDict_Size(kwargs) == 0
                  Pycr.py_wrap({{ klass.id }}.new, subtype)
                {% else %}
                  {% for arg in init_def.args %}
                    py_arg_{{ arg.name }} = Pointer(Void).null.as(Py::Object)
                  {% end %}
                  if Py.PyArg_ParseTupleAndKeywords(args, kwargs, Pycr.cstr({{ format_string }}), Pycr.kwlist({{ klass.id.stringify }} + ".__new__", [{% for arg in init_def.args %}"{{ arg.name }}", {% end %}]){% for arg in init_def.args %}, pointerof(py_arg_{{ arg.name }}){% end %}) == 0
                    next Pointer(Void).null.as(Py::Object)
                  end
                  {% for arg in init_def.args %}
                    {% if !arg.default_value.nil? %}
                      {{ arg.name }} = py_arg_{{ arg.name }}.null? ? ({{ arg.default_value }}).as({{ arg.restriction }}) : Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                    {% else %}
                      {{ arg.name }} = Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                    {% end %}
                  {% end %}
                  Pycr.py_wrap({{ klass.id }}.new({% for arg in init_def.args %}{{ arg.name }}, {% end %}), subtype)
                {% end %}
              end
            end

            {% for method in klass.methods %}
              {% if method.annotation(Pycr::PyMethod) %}
                def self.__pymethod_{{ method.name }}(self_object : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
                  Pycr.py_call do
                    pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
                    {% format_string = "" %}
                    {% for arg in method.args %}
                      {% if !arg.default_value.nil? && !format_string.includes?("|") %}
                        {% format_string = format_string + "|" %}
                      {% end %}
                      {% format_string = format_string + "O" %}
                    {% end %}
                    {% if format_string == "" %}
                      raise TypeCastError.new("{{ method.name }}() takes no keyword arguments") unless kwargs.null? || Py.PyDict_Size(kwargs) == 0
                      Pycr::Conversions.to_python(pycr_receiver.{{ method.name }})
                    {% else %}
                      {% for arg in method.args %}
                        py_arg_{{ arg.name }} = Pointer(Void).null.as(Py::Object)
                      {% end %}
                      if Py.PyArg_ParseTupleAndKeywords(args, kwargs, Pycr.cstr({{ format_string }}), Pycr.kwlist({{ klass.id.stringify }} + ".{{ method.name }}", [{% for arg in method.args %}"{{ arg.name }}", {% end %}]){% for arg in method.args %}, pointerof(py_arg_{{ arg.name }}){% end %}) == 0
                        next Pointer(Void).null.as(Py::Object)
                      end
                      {% for arg in method.args %}
                        {% if !arg.default_value.nil? %}
                          {{ arg.name }} = py_arg_{{ arg.name }}.null? ? ({{ arg.default_value }}).as({{ arg.restriction }}) : Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                        {% else %}
                          {{ arg.name }} = Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                        {% end %}
                      {% end %}
                      Pycr::Conversions.to_python(pycr_receiver.{{ method.name }}({% for arg in method.args %}{{ arg.name }}, {% end %}))
                    {% end %}
                  end
                end
              {% elsif method.annotation(Pycr::PyRepr) %}
                def self.__py_repr(instance : Py::Object) : Py::Object
                  Pycr.py_call do
                    pycr_receiver = Pycr.instance_data(instance).as({{ klass.id }})
                    Pycr::Conversions.to_python(pycr_receiver.{{ method.name }})
                  end
                end
              {% elsif method.annotation(Pycr::PyAttr) %}
                {% if method.return_type %}
                  def self.__pyattr_get_{{ method.name }}(self_object : Py::Object, _closure : Void*) : Py::Object
                    Pycr.py_call do
                      Pycr::Conversions.to_python(Pycr.instance_data(self_object).as({{ klass.id }}).{{ method.name }})
                    end
                  end

                  {% has_setter = false %}
                  {% for sibling in klass.methods %}
                    {% if sibling.name.stringify == method.name.stringify + "=" %}
                      {% has_setter = true %}
                    {% end %}
                  {% end %}
                  {% if has_setter %}
                    def self.__pyattr_set_{{ method.name }}(self_object : Py::Object, value : Py::Object, _closure : Void*) : Int32
                      Pycr.py_call_int do
                        if value.null?
                          raise NotImplementedError.new("cannot delete attribute {{ method.name }}")
                        end
                        Pycr.instance_data(self_object).as({{ klass.id }}).{{ method.name }} = Pycr::Conversions.from_python(value, {{ method.return_type }})
                        0
                      end
                    end
                  {% else %}
                    def self.__pyattr_set_{{ method.name }}(self_object : Py::Object, _value : Py::Object, _closure : Void*) : Int32
                      Pycr.py_call_int do
                        raise NotImplementedError.new("attribute {{ method.name }} is read-only")
                      end
                    end
                  {% end %}
                {% else %}
                  {{ raise klass.id.stringify + "#" + method.name.stringify + " is @[Pycr::PyAttr] but has no return type annotation" }}
                {% end %}
              {% end %}
            {% end %}

            def self.__py_str(instance : Py::Object) : Py::Object
              Pycr.py_call do
                pycr_receiver = Pycr.instance_data(instance).as({{ klass.id }})
                Pycr::Conversions.to_python(pycr_receiver.to_s)
              end
            end
            {% for method in klass.methods %}
              {% if method.annotation(Pycr::PyIter) %}
                def self.__py_iter(self_object : Py::Object) : Py::Object
                  Pycr.py_call do
                    pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
                    pycr_iterator = pycr_receiver.{{ method.name }}
                    pycr_state = Pycr::Classes::IterState.new do
                      pycr_item = pycr_iterator.next
                      if pycr_item.is_a?(Iterator::Stop)
                        nil
                      else
                        pycr_converted = Pycr::Conversions.to_python(pycr_item)
                        raise Pycr::PythonError.new("failed to convert iteration item") if pycr_converted.null?
                        pycr_converted
                      end
                    end
                    Pycr::Classes.new_iterator(pycr_state, self_object)
                  end
                end
              {% end %}
              {% if method.annotation(Pycr::PyLen) %}
                def self.__py_len(self_object : Py::Object) : Int64
                  Pycr.py_call_int64 do
                    Pycr.instance_data(self_object).as({{ klass.id }}).{{ method.name }}.to_i64
                  end
                end
              {% end %}
              {% if method.annotation(Pycr::PyGetItem) %}
                {% raise "PyGetItem requires exactly one key argument" if method.args.size != 1 %}
                def self.__py_getitem(self_object : Py::Object, key_object : Py::Object) : Py::Object
                  Pycr.py_call do
                    pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
                    {% getitem_key = method.args[0].restriction.stringify %}
                    {% if getitem_key == "Int32" || getitem_key == "Int64" %}
                      {% len_name = nil %}
                      {% for m in klass.methods %}
                        {% if m.annotation(Pycr::PyLen) %}
                          {% len_name = m.name %}
                        {% end %}
                      {% end %}
                      {% if len_name %}
                        pycr_bounds = Pycr.unpack_slice(key_object, pycr_receiver.{{ len_name }}.to_i64)
                        unless pycr_bounds.nil?
                          pycr_start, pycr_stop, pycr_step, pycr_count = pycr_bounds
                          pycr_result = Py.PyList_New(pycr_count)
                          pycr_index = pycr_start
                          pycr_i = 0_i64
                          while pycr_i < pycr_count
                            Py.PyList_SetItem(pycr_result, pycr_i, Pycr::Conversions.to_python(pycr_receiver.{{ method.name }}(
                            {% if getitem_key == "Int32" %}
                              pycr_index.to_i32
                            {% else %}
                              pycr_index
                            {% end %}
                          )))
                            pycr_index += pycr_step
                            pycr_i += 1
                          end
                          next pycr_result
                        end
                      {% end %}
                    {% end %}
                    pycr_key = Pycr::Conversions.from_python(key_object, {{ method.args[0].restriction }})
                    Pycr::Conversions.to_python(pycr_receiver.{{ method.name }}(pycr_key))
                  end
                end
              {% end %}
              {% if method.annotation(Pycr::PySetItem) %}
                {% raise "PySetItem requires exactly key and value arguments" if method.args.size != 2 %}
                def self.__py_setitem(self_object : Py::Object, key_object : Py::Object, value_object : Py::Object) : Int32
                  Pycr.py_call_int do
                    raise NotImplementedError.new("deletion is not supported") if value_object.null?
                    pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
                    pycr_key = Pycr::Conversions.from_python(key_object, {{ method.args[0].restriction }})
                    pycr_value = Pycr::Conversions.from_python(value_object, {{ method.args[1].restriction }})
                    pycr_receiver.{{ method.name }}(pycr_key, pycr_value)
                    0
                  end
                end
              {% end %}
              {% if method.annotation(Pycr::PyContains) %}
                {% raise "PyContains requires exactly one argument" if method.args.size != 1 %}
                def self.__py_contains(self_object : Py::Object, key_object : Py::Object) : Int32
                  Pycr.py_call_int do
                    pycr_receiver = Pycr.instance_data(self_object).as({{ klass.id }})
                    pycr_key = Pycr::Conversions.from_python(key_object, {{ method.args[0].restriction }})
                    pycr_receiver.{{ method.name }}(pycr_key) ? 1 : 0
                  end
                end
              {% end %}
            {% end %}

            def self.__py_register(module_object : Py::Object) : Nil
              Pycr::Classes.register_class(
                module_object,
                {{ class_name }},
                self,
                [
                  {% for method in klass.methods %}
                    {% if method.annotation(Pycr::PyMethod) %}
                      {"{{ method.name }}", ->__pymethod_{{ method.name }}(Py::Object, Py::Object, Py::Object)},
                    {% end %}
                  {% end %}
                ],
                ->__py_new(Py::Object, Py::Object, Py::Object),
                ->Pycr::PyObject.py_dealloc(Py::Object),
                {% if has_repr %}
                  ->__py_repr(Py::Object),
                {% else %}
                  nil,
                {% end %}
                ->__py_str(Py::Object),
                {% if has_iter %}
                  ->__py_iter(Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_len %}
                  ->__py_len(Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_getitem %}
                  ->__py_getitem(Py::Object, Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_setitem %}
                  ->__py_setitem(Py::Object, Py::Object, Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_contains %}
                  ->__py_contains(Py::Object, Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_compare %}
                  ->__py_compare(Py::Object, Py::Object, Int32),
                {% else %}
                  nil,
                {% end %}
                {% if has_add %}
                  ->__py_add(Py::Object, Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_sub %}
                  ->__py_sub(Py::Object, Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_mul %}
                  ->__py_mul(Py::Object, Py::Object),
                {% else %}
                  nil,
                {% end %}
                {% if has_attrs %}
                  [
                    {% for method in klass.methods %}
                      {% if method.annotation(Pycr::PyAttr) %}
                        {"{{ method.name }}", ->__pyattr_get_{{ method.name }}(Py::Object, Void*), ->__pyattr_set_{{ method.name }}(Py::Object, Py::Object, Void*)},
                      {% end %}
                    {% end %}
                  ]
                {% else %}
                  [] of Pycr::Classes::GetSetEntry
                {% end %}
              )
            end
          end
        {% else %}
          {{ raise klass.id.stringify + " carries @[Pycr::PyClass] but its initialize is not annotated with @[Pycr::PyNew]" }}
        {% end %}
      {% end %}
    {% end %}

    fun pyinit_{{ module_name.id }} = PyInit_{{ module_name.id }} : Py::Object
      Pycr.bootstrap_module({{ module_name }}, {{ function_count }})
      {% method_index = 0 %}
      {% for node in nodes %}
        {% if node.class_name == "Call" && node.name == :pyfunction %}
          {% if node.args[0].class_name == "Def" %}
            {% table_name = node.args[0].name %}
            {% thunk_name = node.args[0].name %}
          {% else %}
            {% table_name = node.args[0].name %}
            {% thunk_name = node.args[1].name %}
          {% end %}
          Pycr.set_method(Pycr.method_table, {{ method_index }}, "{{ table_name }}", ->__pyfunction_{{ thunk_name }}(Py::Object, Py::Object, Py::Object))
          {% method_index = method_index + 1 %}
        {% end %}
      {% end %}
      module_object = Py.PyModule_Create2(Pycr.module_definition, PYTHON_API_VERSION)
      if module_object.null?
        Pointer(Void).null.as(Py::Object)
      else
        # Free-threaded builds: declare GIL-free operation (no-op on
        # GIL builds; keeps the GIL off on 3.13t/3.14t).
        Pycr.set_module_gil(module_object)
        {% exposed_classes = Pycr::PyObject.all_subclasses %}
        {% unless exposed_classes.empty? && block_classes.empty? %}
          Pycr::Classes.bootstrap(module_object, [{% for klass in exposed_classes %}->{{ klass }}.__py_register(Py::Object), {% end %}{% for klass in block_classes %}->{{ klass }}.__py_register(Py::Object), {% end %}])
        {% end %}
        module_object
      end
    end
  end
end
