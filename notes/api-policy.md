# CPython API contract policy

How py-cr binds to CPython, what is guaranteed, and what is assumed.
Audit date: 2026-09-28, against the CPython 3.14 stable ABI list
(docs.python.org/3/c-api/stable.html).

## Policy

1. **Statically declared symbols must be stable ABI.** Every `fun` in
   `lib Py` resolves at load time from the host interpreter; if it is
   not guaranteed across 3.11-3.14, it does not get a static
   declaration.
2. **Everything else is resolved at runtime via dlsym**, guarded, and
   treated as optional: `PyUnstable_Module_SetGIL` (FT import gating),
   `PyUnstable_Object_ClearWeakRefsNoCallbacks` and
   `PyObject_ClearManagedDict` (subclass teardown, 3.12+).
3. **Struct mirrors are annotated with their contract source** (see
   below). Layouts are re-verified by diffing headers per CPython
   version (identical across 3.14 regular/free-threaded as of this
   audit) and by the CI matrix.

## Audit result (all statically declared Py* symbols)

Stable ABI (49/49): PyArg_ParseTuple, PyArg_ParseTupleAndKeywords,
PyBool_FromLong, PyBytes_AsStringAndSize, PyBytes_FromStringAndSize,
PyCallable_Check, PyCapsule_GetPointer, PyCapsule_New, PyDict_New,
PyDict_Next, PyDict_SetItem, PyDict_Size, PyErr_Clear, PyErr_Occurred,
PyErr_SetString, PyEval_RestoreThread, PyEval_SaveThread,
PyFloat_AsDouble, PyFloat_FromDouble, PyGILState_Ensure,
PyGILState_Release, PyIter_Check, PyList_GetItem, PyList_New,
PyList_SetItem, PyList_Size, PyLong_AsLongLong, PyLong_FromLongLong,
PyModule_AddObject, PyModule_Create2, PyObject_Call,
PyObject_ClearManagedDict* (see deviations), PyObject_Free,
PyObject_GC_Del, PyObject_GC_UnTrack, PyObject_IsInstance,
PyObject_IsTrue, PySlice_AdjustIndices, PySlice_Unpack, PyTuple_New,
PyTuple_SetItem, PyType_FromSpec, PyType_GenericAlloc, PyType_GetFlags,
PyUnicode_AsUTF8AndSize, PyUnicode_FromString, Py_BuildValue,
Py_DecRef, Py_IncRef.

(* PyObject_ClearManagedDict is dlsym'd, not static - new in 3.12 and
absent from 3.11, where subclasses use plain refcounted dicts.)

dlsym'd (not statically declared, all optional/guarded):
- PyUnstable_Module_SetGIL - free-threaded import gating (3.13t+)
- PyUnstable_Object_ClearWeakRefsNoCallbacks - subclass teardown
- PyObject_ClearManagedDict - managed dict teardown (3.12+)

Non-CPython symbols (Boehm LibGC, LibC pthread/dlsym) are outside this
policy; see notes/scheduler-spike.md for the Boehm threading design.

## Struct mirrors and their contract status

| struct | contract | notes |
|---|---|---|
| PyModuleDef | de-facto stable | allocated by us, passed to PyModule_Create2 (stable fn); extra trailing fields zeroed; m_slots used on 3.12+ |
| PyMethodDef | de-facto stable | {name, meth, flags, doc}; doc NULL |
| PyGetSetDef | de-facto stable | {name, get, set, doc=NULL, closure=NULL} |
| PyType_Spec / PyType_Slot | **stable ABI contract** | PyType_FromSpec is the limited-API type creation mechanism; slot ids from typeslots.h (verified identical 3.11/3.14) |
| TypeSlot{New,Unary,Dealloc,Len,Subscript,AssSubscript,Contains,Compare} | ours | typed-view helpers over PyType_Slot {int, pad, void*}; exist so Crystal proc literals convert without raw pointer casts |
| PyObject head | stable (ob_refcnt, ob_type) | only read ob_type (+8) |

## Layout assumptions outside any API contract

These are design invariants, verified by tests, not guaranteed by
CPython:

- `Pycr::INSTANCE_DATA_OFFSET = 16` - instance data of exposed classes
  lives at offset 16 (right after the PyObject head); base basicsize is
  24. Python subclass instances extend past it (managed dict/weakref
  live in the preheader or after), leaving our region untouched.
- ob_type read at offset 8 (`Pycr.py_type`) - PyObject head is frozen
  by CPython's own ABI docs.

Free-threaded builds: 3.14t headers are byte-identical to regular
3.14 (verified by diff); see notes/scheduler-spike.md for FT status.

## Per-release checklist

1. `diff` CPython headers (object.h, moduleobject.h, methodobject.h,
   descrobject.h, typeslots.h) regular vs previous version.
2. Build + run all suites on the new version and on 3.11 (oldest
   supported).
3. Re-check new symbols against the stable ABI list if any were added.
4. Re-run `python3 -m venv` install test from the built wheel.
