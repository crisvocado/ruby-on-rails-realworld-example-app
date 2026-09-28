# frozen_string_literal: true

module Logcore
  module Context
    THREAD_KEY_TRACE = :logcore_current_trace
    THREAD_KEY_CONTEXT = :logcore_current_context

    def self.current_trace
      Thread.current[THREAD_KEY_TRACE]
    end

    def self.current_trace=(trace)
      Thread.current[THREAD_KEY_TRACE] = trace
    end

    def self.with_trace(trace)
      prev = Thread.current[THREAD_KEY_TRACE]
      Thread.current[THREAD_KEY_TRACE] = trace
      yield
    ensure
      Thread.current[THREAD_KEY_TRACE] = prev
    end

    def self.current_context
      Thread.current[THREAD_KEY_CONTEXT] ||= {}
    end

    def self.with_context(ctx)
      prev = Thread.current[THREAD_KEY_CONTEXT]
      Thread.current[THREAD_KEY_CONTEXT] = (prev || {}).merge(ctx || {})
      yield
    ensure
      Thread.current[THREAD_KEY_CONTEXT] = prev
    end

    def self.clear!
      Thread.current[THREAD_KEY_TRACE] = nil
      Thread.current[THREAD_KEY_CONTEXT] = nil
    end
  end
end
