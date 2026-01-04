# frozen_string_literal: true

module Kira
  module Support
    class Hysteresis
      attr_reader :state, :enter_threshold, :exit_threshold, :min_dwell_ms

      def initialize(enter_threshold:, exit_threshold:, min_dwell_ms: 0)
        raise ArgumentError, 'exit_threshold must be less than enter_threshold' unless exit_threshold < enter_threshold

        @enter_threshold = enter_threshold
        @exit_threshold = exit_threshold
        @min_dwell_ms = min_dwell_ms
        @state = false
        @last_transition_ms = 0
      end

      def update(value, timestamp_ms)
        time_in_state = timestamp_ms - @last_transition_ms

        if !@state && value > @enter_threshold && time_in_state >= @min_dwell_ms
          @state = true
          @last_transition_ms = timestamp_ms
        elsif @state && value < @exit_threshold && time_in_state >= @min_dwell_ms
          @state = false
          @last_transition_ms = timestamp_ms
        end

        @state
      end

      def active?
        @state
      end

      def reset
        @state = false
        @last_transition_ms = 0
      end
    end
  end
end
