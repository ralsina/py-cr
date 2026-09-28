# Pycr::Bridge: lets foreign Python threads run scheduler-requiring
# Crystal code (sleep, spawn, channels, IO).
#
# Design (AdoptingContext): foreign threads cannot enter Crystal's
# execution contexts by default - stock Crystal 1.21 gives lazily
# adopted threads no execution_context - but the execution context
# interface is public and pluggable. Pycr::AdoptingContext enrolls the
# calling thread by setting its execution_context/scheduler to a
# single-fiber context (Isolated semantics: suspend blocks the thread
# in the context's event loop; no fiber swapping, since the thread's
# root fiber runs the Python stack). See notes/scheduler-spike.md.
#
# GIL discipline: the work block runs under Pycr.release_gil, so other
# Python threads keep running during sleeps and blocking IO. The block
# must not touch Python objects or the C API - convert results to
# Crystal values inside the block, to Python values after run returns.
#
# Spawn semantics (Isolated-like): bare `spawn` inside a block routes
# to the default EC (the importing thread), where queued fibers run
# when that thread next pumps its own scheduler. Prefer blocking IO in
# bridge blocks.

module Pycr
  module Bridge
    # Set at import (via __crystal_main) on the importing thread.
    @@importer_thread : LibC::PthreadT = LibC.pthread_self

    # Runs *work*, adopting the calling thread first when needed. On
    # the importing thread this is a plain call (that thread is
    # already enrolled in the default context). Exceptions propagate
    # with their Crystal type (mapped at the boundary).
    def self.run(&work : -> T) : T forall T
      if LibC.pthread_self == @@importer_thread
        return work.call
      end

      adopt
      Pycr.release_gil do
        work.call
      end
    end

    # Enrolls the calling thread in an AdoptingContext (once per
    # thread); subsequent scheduler-requiring calls on this thread
    # work with no further setup.
    #
    # The adoption check lives on the Thread object itself, NOT in a
    # cache keyed by pthread id: glibc recycles pthread_t values after
    # a thread exits, so an id-keyed cache makes a recycled thread skip
    # adoption (observed as NilAssertionError on the second sequential
    # foreign thread).
    def self.adopt : Nil
      thread = Thread.current
      already = begin
        thread.execution_context.is_a?(AdoptingContext)
      rescue Exception
        false # getter! raises on nil: not yet adopted
      end
      AdoptingContext.for_current_thread("pycr-adapted") unless already
    end
  end
end
