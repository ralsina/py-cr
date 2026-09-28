# SPIKE (rung 1): AdoptingContext - an execution context that enrolls
# the CURRENT thread instead of creating one.
#
# Modeled directly on Fiber::ExecutionContext::Isolated minus thread
# creation: a single-fiber context where "suspend" blocks the thread in
# the event loop (no fiber swap - there is only one fiber, and it runs
# the foreign thread's Python stack). The adopt step sets the lazy
# Thread's execution_context/scheduler so the suspension path
# (sleep -> EventLoop.current -> Thread.current.scheduler.@event_loop)
# resolves to us.
#
# Semantics mirror Isolated: spawn routes to @spawn_context (the
# default EC); sleep and blocking IO block the thread; timers and IO
# resume via the context's event loop.

module Pycr
  class AdoptingContext
    include Fiber::ExecutionContext
    include Fiber::ExecutionContext::Scheduler

    getter name : String

    @mutex = Thread::Mutex.new
    @condition = Thread::ConditionVariable.new
    @main_fiber : Fiber
    @enqueued = false
    @waiting = false
    @running = true

    # :nodoc:
    getter(event_loop : Crystal::EventLoop) do
      evloop = Crystal::EventLoop.create(parallelism: 1)
      evloop.register(self, index: 0)
      evloop
    end

    # Enrolls the calling thread into a new AdoptingContext. The thread
    # must not be enrolled in another context.
    def self.for_current_thread(name : String) : self
      thread = Thread.current
      context = new(name, thread)
      thread.execution_context = context
      thread.scheduler = context
      context
    end

    def initialize(@name : String, @thread : Thread)
      @main_fiber = @thread.main_fiber
    end

    # :nodoc:
    def execution_context : AdoptingContext
      self
    end

    getter thread : Thread
    setter thread : Thread

    getter main_fiber : Fiber

    def each_scheduler(& : Scheduler ->) : Nil
      yield self
    end

    # :nodoc:
    def stack_pool : Fiber::StackPool
      raise RuntimeError.new("No stack pool for adopting contexts")
    end

    # :nodoc:
    def stack_pool? : Fiber::StackPool?
    end

    # Spawned fibers land on the default context - Isolated semantics.
    # Blocking IO and sleep work directly on the adopting thread.
    def spawn(*, name : String? = nil, &block : ->) : Fiber
      Fiber::ExecutionContext.default.spawn(name: name, &block)
    end

    # :nodoc:
    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      Fiber::ExecutionContext.default.spawn(name: name, &block)
    end

    # :nodoc:
    def enqueue(fiber : Fiber) : Nil
      enqueue_impl(fiber)
    end

    # :nodoc:
    def external_enqueue(fiber : Fiber) : Nil
      enqueue_impl(fiber)
    end

    private def enqueue_impl(fiber : Fiber) : Nil
      unless fiber == @main_fiber
        raise RuntimeError.new("Concurrency is disabled in adopting contexts")
      end

      @mutex.synchronize do
        raise RuntimeError.new("Can't resume dead fiber") unless @running

        @enqueued = true

        if @waiting
          @waiting = false
          event_loop.interrupt
        else
          # race: enqueued before the thread started waiting
        end
      end
    end

    protected def reschedule : Nil
      wait_for(event_loop)
    end

    protected def resume(fiber : Fiber) : Nil
      raise RuntimeError.new("Can't resume #{fiber} in #{self}")
    end

    # :nodoc:
    def status : String
      @waiting ? "event-loop" : "running"
    end

    private def wait_for(event_loop : Crystal::EventLoop) : Nil
      loop do
        @mutex.synchronize do
          return if check_enqueued?
          @waiting = true
        end

        # block the thread in the event loop until the main fiber's
        # pending event (timer, IO) completes or an enqueue interrupts
        list = Fiber::List.new
        event_loop.run(pointerof(list), blocking: true)

        next unless fiber = list.pop?

        unless fiber == @main_fiber && list.empty?
          raise RuntimeError.new("Concurrency is disabled in adopting contexts")
        end

        break
      end

      @mutex.synchronize do
        @waiting = false
        @enqueued = false
      end
    end

    private def check_enqueued? : Bool
      if @enqueued
        @enqueued = false
        @waiting = false
        true
      else
        false
      end
    end
  end
end
