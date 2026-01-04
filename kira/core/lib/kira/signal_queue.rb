# frozen_string_literal: true

module Kira
  # Priority queue for signals. Higher priority signals are processed first.
  # Thread-safe for concurrent producers (signal sources) and single consumer (orchestrator).
  class SignalQueue
    def initialize
      @queue = []
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @closed = false
    end

    def push(signal)
      @mutex.synchronize do
        return if @closed

        # Insert in priority order (higher priority first)
        insert_idx = @queue.bsearch_index { |s| s.priority < signal.priority } || @queue.size
        @queue.insert(insert_idx, signal)
        @cond.signal
      end
    end

    alias << push

    def pop(timeout: nil)
      @mutex.synchronize do
        if @queue.empty?
          return nil if @closed
          return nil if timeout&.zero?

          @cond.wait(@mutex, timeout)
          return nil if @queue.empty?
        end

        @queue.shift
      end
    end

    def clear
      @mutex.synchronize { @queue.clear }
    end

    def size
      @mutex.synchronize { @queue.size }
    end

    def empty?
      @mutex.synchronize { @queue.empty? }
    end

    def close
      @mutex.synchronize do
        @closed = true
        @cond.broadcast
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end
  end
end
