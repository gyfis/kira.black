# frozen_string_literal: true

module Kira
  module Output
    class Decision
      attr_reader :action, :reason, :delay_ms, :trigger

      def initialize(action:, reason: nil, delay_ms: nil, trigger: nil)
        @action = action
        @reason = reason
        @delay_ms = delay_ms
        @trigger = trigger
      end

      def speak?
        @action == :speak
      end

      def delayed?
        @action == :delayed
      end

      def blocked?
        @action == :blocked
      end

      class << self
        def speak(trigger = nil)
          new(action: :speak, trigger: trigger)
        end

        def delayed(delay_ms, trigger)
          new(action: :delayed, delay_ms: delay_ms, trigger: trigger)
        end

        def blocked(reason)
          new(action: :blocked, reason: reason)
        end

        def no_trigger
          new(action: :no_trigger)
        end

        def cooldown(event_type)
          new(action: :blocked, reason: "cooldown for #{event_type}")
        end
      end
    end

    class SpeakDecisionEngine
      def initialize(config:)
        @speak_rules = config.interaction_rules.speak_when
        @silence_rules = config.interaction_rules.do_not_speak_when
        @cooldown_tracker = {}
        @last_spoke_at = nil
      end

      def should_speak?(state:, events:, timestamp_ms:)
        silence_reason = check_silence_rules(state, events, timestamp_ms)
        return Decision.blocked(silence_reason) if silence_reason

        trigger, delay = check_speak_rules(state, events)
        return Decision.no_trigger if trigger.nil?

        event_type = trigger[:event]
        return Decision.cooldown(event_type) if event_type && in_cooldown?(event_type, timestamp_ms)

        return Decision.delayed(delay, trigger) if delay && delay > 0

        Decision.speak(trigger)
      end

      def mark_spoke(timestamp_ms:)
        @last_spoke_at = timestamp_ms
      end

      private

      def check_silence_rules(state, _events, timestamp_ms)
        @silence_rules.each do |rule|
          condition = rule[:condition].to_s

          case condition
          when 'user_is_speaking'
            return 'user_is_speaking' if state_indicates_speaking?(state)
          when /time_since_last_response_ms < (\d+)/
            threshold = ::Regexp.last_match(1).to_i
            return "too_soon (#{threshold}ms cooldown)" if @last_spoke_at && (timestamp_ms - @last_spoke_at) < threshold
          else
            return rule[:reason] || condition if evaluate_condition(condition, state)
          end
        end

        nil
      end

      def check_speak_rules(state, events)
        @speak_rules.each do |rule|
          if rule[:event]
            matching_event = events.find { |e| e.type == rule[:event].to_s }
            next unless matching_event

            next if rule[:condition] && !evaluate_event_condition(rule[:condition], matching_event)

            return [rule, rule[:delay_ms] || 0]
          elsif evaluate_condition(rule[:condition], state)
            return [rule, rule[:delay_ms] || 0]
          end
        end

        [nil, nil]
      end

      def state_indicates_speaking?(_state)
        false
      end

      def evaluate_condition(_condition, _state)
        false
      end

      def evaluate_event_condition(condition, event)
        case condition.to_s
        when /severity >= (\w+)/
          severity_rank(event.severity) >= severity_rank(::Regexp.last_match(1))
        when /severity == (\w+)/
          event.severity == ::Regexp.last_match(1)
        else
          true
        end
      end

      def severity_rank(severity)
        %w[debug info notice warning alert].index(severity.to_s) || 0
      end

      def in_cooldown?(event_type, timestamp_ms)
        cooldown_end = @cooldown_tracker[event_type]
        return false unless cooldown_end

        timestamp_ms < cooldown_end
      end

      def mark_cooldown(event_type, timestamp_ms, duration_ms)
        @cooldown_tracker[event_type] = timestamp_ms + duration_ms
      end
    end
  end
end
