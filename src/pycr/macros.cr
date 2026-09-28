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

  macro pyclass(klass, python_name, &block)
    {% nodes = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
    class {{ klass.id }} < Pycr::PyObject
      {% has_repr = false %}
      {% has_attrs = false %}
      {% for node in nodes %}
        {% if node.class_name == "Call" && node.name == :pyattr %}
          {% has_attrs = true %}
        {% end %}
        {% if node.class_name == "Call" && node.name == :pynew %}
          {% init_def = node.args[0] %}
          {{ init_def }}

          def self.__py_new(subtype : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
            Pycr.py_call do
              {% format_string = "" %}
              {% for arg in init_def.args %}
                {% if arg.default_value && !format_string.includes?("|") %}
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
                  {% if arg.default_value %}
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
                {% if arg.default_value && !format_string.includes?("|") %}
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
                  {% if arg.default_value %}
                    {{ arg.name }} = py_arg_{{ arg.name }}.null? ? ({{ arg.default_value }}).as({{ arg.restriction }}) : Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                  {% else %}
                    {{ arg.name }} = Pycr::Conversions.from_python(py_arg_{{ arg.name }}, {{ arg.restriction }})
                  {% end %}
                {% end %}
                Pycr::Conversions.to_python(pycr_receiver.{{ method_def.name }}({% for arg in method_def.args %}{{ arg.name }}, {% end %}))
              {% end %}
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

      def self.__py_register(module_object : Py::Object) : Nil
        Pycr::Classes.register_class(
          module_object,
          {{ python_name }},
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
          {% if has_attrs %}
            [
              {% for node in nodes %}
                {% if node.class_name == "Call" && node.name == :pyattr %}
                  {% for attr in node.args %}
                    {% attr_name = attr.class_name == "TypeDeclaration" ? attr.var : attr.name %}
                    {"{{ attr_name }}", ->__pyattr_get_{{ attr_name }}(Py::Object, Void*), ->__pyattr_set_{{ attr_name }}(Py::Object, Py::Object, Void*)},
                  {% end %}
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
              {% if arg.default_value && !format_string.includes?("|") %}
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
                {% if arg.default_value %}
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
        {% end %}
        {% if init_def %}
          class {{ klass.id }}
            def self.__py_new(subtype : Py::Object, args : Py::Object, kwargs : Py::Object) : Py::Object
              Pycr.py_call do
                {% format_string = "" %}
                {% for arg in init_def.args %}
                  {% if arg.default_value && !format_string.includes?("|") %}
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
                    {% if arg.default_value %}
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
                      {% if arg.default_value && !format_string.includes?("|") %}
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
                        {% if arg.default_value %}
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

            def self.__py_register(module_object : Py::Object) : Nil
              Pycr::Classes.register_class(
                module_object,
                {{ class_name }},
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
        {% exposed_classes = Pycr::PyObject.all_subclasses %}
        {% unless exposed_classes.empty? && block_classes.empty? %}
          Pycr::Classes.bootstrap(module_object, [{% for klass in exposed_classes %}->{{ klass }}.__py_register(Py::Object), {% end %}{% for klass in block_classes %}->{{ klass }}.__py_register(Py::Object), {% end %}])
        {% end %}
        module_object
      end
    end
  end
end
