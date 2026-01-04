# frozen_string_literal: true

module Kira
  # A Signal represents an observation from any input source.
  # Signals are processed by the Orchestrator to decide if/how Kira should respond.
  class Signal
    # Signal types ordered by priority (higher = more urgent)
    PRIORITIES = {
      voice: 100,      # User spoke - always highest priority
      interrupt: 90,   # User wants to interrupt
      screen: 50,      # Screen content changed
      visual: 30,      # Camera observation
      system: 10       # System events
    }.freeze

    attr_reader :type, :content, :metadata, :timestamp, :priority

    def initialize(type:, content:, metadata: {}, timestamp: nil)
      @type = type.to_sym
      @content = content
      @metadata = metadata
      @timestamp = timestamp || Time.now
      @priority = PRIORITIES.fetch(@type, 0)
    end

    def voice?
      @type == :voice
    end

    def requires_response?
      # Voice always requires response, others depend on orchestrator decision
      voice?
    end

    def to_h
      {
        type: @type,
        content: @content,
        metadata: @metadata,
        timestamp: @timestamp,
        priority: @priority
      }
    end
  end
end
