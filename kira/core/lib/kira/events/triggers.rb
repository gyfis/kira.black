# frozen_string_literal: true

module Kira
  module Events
    TriggerResult = Struct.new(
      :fired, :signal_value, :threshold, :from_value, :to_value,
      :duration_ms, :reason, keyword_init: true
    ) do
      def fired?
        fired == true
      end
    end

    class BaseTrigger
      def initialize(definition)
        @definition = definition
      end

      def evaluate(state, previous_state, history)
        raise NotImplementedError
      end

      protected

      def extract_signal(path, state)
        return nil if state.nil?

        path.to_s.split('.').reduce(state) do |obj, key|
          return nil if obj.nil?

          case obj
          when Hash
            obj[key.to_sym] || obj[key]
          when Array
            key =~ /^\d+$/ ? obj[key.to_i] : nil
          when Dry::Struct
            obj.respond_to?(key) ? obj.send(key) : nil
          else
            obj.respond_to?(key) ? obj.send(key) : nil
          end
        end
      end

      def evaluate_condition(condition, value)
        return false if value.nil?

        case condition.to_s
        when /^< (.+)$/
          value < ::Regexp.last_match(1).to_f
        when /^> (.+)$/
          value > ::Regexp.last_match(1).to_f
        when /^<= (.+)$/
          value <= ::Regexp.last_match(1).to_f
        when /^>= (.+)$/
          value >= ::Regexp.last_match(1).to_f
        when /^== (.+)$/
          value.to_s == ::Regexp.last_match(1)
        when /^!= (.+)$/
          value.to_s != ::Regexp.last_match(1)
        else
          false
        end
      end
    end

    class ThresholdTrigger < BaseTrigger
      def initialize(definition, hysteresis: nil)
        super(definition)
        @hysteresis = hysteresis
      end

      def evaluate(state, _previous_state, _history)
        signal_value = extract_signal(@definition[:signal], state)
        return TriggerResult.new(fired: false, reason: 'signal not found') if signal_value.nil?

        condition_met = evaluate_condition(@definition[:condition], signal_value)

        fired = if @hysteresis
                  @hysteresis.update(signal_value, state.timestamp.session_elapsed_ms)
                else
                  condition_met
                end

        TriggerResult.new(
          fired: fired,
          signal_value: signal_value,
          threshold: extract_threshold(@definition[:condition])
        )
      end

      private

      def extract_threshold(condition)
        condition.to_s.match(/[\d.]+/)&.[](0)&.to_f
      end
    end

    class StateChangeTrigger < BaseTrigger
      def evaluate(state, previous_state, _history)
        signal = @definition[:signal]
        current = extract_signal(signal, state)
        previous = extract_signal(signal, previous_state)

        fired = current != previous

        if @definition[:from] && @definition[:to]
          fired = previous.to_s == @definition[:from].to_s &&
                  current.to_s == @definition[:to].to_s
        elsif @definition[:to]
          fired = current.to_s == @definition[:to].to_s && current != previous
        end

        TriggerResult.new(
          fired: fired,
          from_value: previous,
          to_value: current
        )
      end
    end

    class DurationTrigger < BaseTrigger
      def initialize(definition)
        super
        @condition_start_ms = nil
      end

      def evaluate(state, _previous_state, _history)
        signal_value = extract_signal(@definition[:signal], state)
        return TriggerResult.new(fired: false, reason: 'signal not found') if signal_value.nil?

        condition_met = evaluate_condition(@definition[:condition], signal_value)
        current_ms = state.timestamp.session_elapsed_ms

        if condition_met
          @condition_start_ms ||= current_ms
          elapsed = current_ms - @condition_start_ms

          TriggerResult.new(
            fired: elapsed >= @definition[:duration_ms],
            duration_ms: elapsed,
            signal_value: signal_value
          )
        else
          @condition_start_ms = nil
          TriggerResult.new(fired: false, duration_ms: 0)
        end
      end
    end

    class EntityLifecycleTrigger < BaseTrigger
      def evaluate(state, previous_state, _history)
        current_ids = Set.new(state.entities.map(&:id))
        previous_ids = previous_state ? Set.new(previous_state.entities.map(&:id)) : Set.new

        case @definition[:lifecycle_event]
        when 'appeared'
          new_ids = current_ids - previous_ids
          if new_ids.any?
            TriggerResult.new(
              fired: true,
              to_value: new_ids.first,
              reason: "entity appeared: #{new_ids.first}"
            )
          else
            TriggerResult.new(fired: false)
          end
        when 'disappeared'
          gone_ids = previous_ids - current_ids
          if gone_ids.any?
            TriggerResult.new(
              fired: true,
              from_value: gone_ids.first,
              reason: "entity disappeared: #{gone_ids.first}"
            )
          else
            TriggerResult.new(fired: false)
          end
        else
          TriggerResult.new(fired: false, reason: 'unknown lifecycle event')
        end
      end
    end
  end
end
