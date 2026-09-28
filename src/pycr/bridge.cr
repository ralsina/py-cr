# Pycr::Bridge: intended to let foreign Python threads run
# scheduler-requiring Crystal code (sleep, spawn, channels, IO).
#
# CURRENT STATE: a stub. On the importing thread, run executes the
# block directly. From foreign threads it raises NotImplementedError.
#
# Two full implementations were built and abandoned tonight (see
# notes/scheduler-spike.md for the complete evidence trail):
#
#   - Isolated-context funnel: Isolated forbids spawning fibers onto
#     itself and routes bare `spawn` to the default EC (the importing
#     thread), where queued fibers never run while Python owns that
#     thread -> deadlock for any spawn-using block.
#   - Parallel-context funnel (capacity 1): jobs ran - the FIRST one.
#     Subsequent external enqueues never woke the parked scheduler
#     (deterministically reproducible), and the context creation was
#     itself nondeterministically hang-prone depending on which thread
#     and when.
#
# The protocol design (raw pthread mutex/condvar handoff, GIL released
# for the whole wait, no Python access inside blocks) is sound and
# tested; what is missing is an execution context that can be driven
# from a foreign thread - an upstream Crystal gap (adopting-EC API).
# The notes contain the repros and the design, ready for when that
# gap closes or for a fork.

module Pycr
  module Bridge
    # Set at import (via __crystal_main) on the importing thread.
    @@importer_thread : LibC::PthreadT = LibC.pthread_self

    # Runs *work* on the importing thread. From foreign threads raises
    # NotImplementedError: scheduler-requiring work cannot run there
    # (stock Crystal 1.21 limitation; no adopting execution context).
    def self.run(&work : -> T) : T forall T
      if LibC.pthread_self != @@importer_thread
        raise NotImplementedError.new(
          "Pycr::Bridge.run from foreign threads is not available yet " \
          "(no adopting execution context; call this function from the " \
          "importing thread)"
        )
      end
      work.call
    end
  end
end
