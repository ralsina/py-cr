# Reproducer for a Crystal 1.21.0 compiler crash found through py-cr.
#
# An overloaded module method called with a NoReturn argument (a
# raise-only def) inside a typed, closured block makes the compiler
# abort with:
#
#   Cast from Nil to Crystal::ProcInstanceType failed, at
#   src/compiler/crystal/semantic/bindings.cr:596 (TypeCastError)
#
# Each ingredient alone compiles; only the combination crashes.
#
# Workaround in py-cr: Pycr.py_call uses a plain yield block instead
# of a typed &block, which avoids the Proc conversion entirely.
#
# Run: crystal notes/crystal-1.21-no-return-proc-bug.cr

alias Obj = Pointer(Void)

module Conv
  def self.to_python(value : Nil) : Obj
    Obj.null
  end

  def self.to_python(value : String) : Obj
    Obj.null
  end
end

module Boundary
  def self.py_call(&block : -> Obj) : Obj
    block.call
  rescue Exception
    Obj.null
  end
end

def boom : Nil
  raise "boom"
end

def __pyfunction_boom(_module_self : Obj, args : Obj) : Obj
  Boundary.py_call do
    Conv.to_python(boom)
  end
end

puts __pyfunction_boom(Obj.null, Obj.null)
