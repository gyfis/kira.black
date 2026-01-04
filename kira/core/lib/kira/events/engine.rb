# frozen_string_literal: true

require 'securerandom'

module Kira
  module Events
    class Engine
      attr_reader :registry

      def initialize(registry: nil)
        @registry = registry || Registry.new
        @trigger_instances = {}
        @cooldowns = {}
        @hysteresis_states = {}
        @callbacks = []
      end

      def on_event(&block)
        @callbacks << block
      end

      def evaluate(state, previous_state, history)
        events = []

        @registry.each do |event_def|
          next if in_cooldown?(event_def)

          trigger = get_or_create_trigger(event_def)
          result = trigger.evaluate(state, previous_state, history)

          next unless result.fired?

          event = build_event(event_def, result, state)
          events << event
          mark_cooldown(event_def, state.timestamp.session_elapsed_ms)
          notify_callbacks(event)
        end

        events
      end

      def configure_from_profile(profile_config)
        @registry.clear

        if profile_config[:enabled_categories]
          @registry.register_standard_events(
            categories: profile_config[:enabled_categories]
          )
        end

        (profile_config[:custom_events] || []).each do |custom|
          @registry.register(custom)
        end

        (profile_config[:severity_overrides] || {}).each do |type, severity|
          @registry.override_severity(type.to_s, severity)
        end
      end

      def reset
        @trigger_instances.clear
        @cooldowns.clear
        @hysteresis_states.clear
      end

      private

      def get_or_create_trigger(event_def)
        @trigger_instances[event_def.id] ||= create_trigger(event_def.trigger)
      end

      def create_trigger(trigger_def)
        trigger_def = trigger_def.transform_keys(&:to_sym)

        case trigger_def[:type]
        when 'threshold', 'threshold_crossing'
          hysteresis = (get_or_create_hysteresis(trigger_def) if trigger_def[:hysteresis])
          Kira::Events::ThresholdTrigger.new(trigger_def, hysteresis: hysteresis)
        when 'state_change'
          Kira::Events::StateChangeTrigger.new(trigger_def)
        when 'duration'
          Kira::Events::DurationTrigger.new(trigger_def)
        when 'lifecycle'
          Kira::Events::EntityLifecycleTrigger.new(trigger_def)
        else
          raise ArgumentError, "Unknown trigger type: #{trigger_def[:type]}"
        end
      end

      def get_or_create_hysteresis(trigger_def)
        key = trigger_def[:id] || trigger_def[:signal]
        @hysteresis_states[key] ||= Support::Hysteresis.new(
          enter_threshold: trigger_def.dig(:hysteresis, :enter) || 0.5,
          exit_threshold: trigger_def.dig(:hysteresis, :exit) || 0.3,
          min_dwell_ms: trigger_def.dig(:hysteresis, :min_dwell_ms) || 0
        )
      end

      def in_cooldown?(event_def)
        cooldown_end = @cooldowns[event_def.id]
        return false unless cooldown_end

        Time.now.to_f * 1000 < cooldown_end
      end

      def mark_cooldown(event_def, _current_ms)
        @cooldowns[event_def.id] = Time.now.to_f * 1000 + event_def.cooldown_ms
      end

      def build_event(event_def, result, state)
        now = Time.now

        Event.new(
          event_id: "evt_#{SecureRandom.hex(8)}",
          type: event_def.type,
          category: event_def.category,
          severity: @registry.effective_severity(event_def),
          confidence: 1.0,
          timestamp: EventTimestamp.new(
            occurred_at: now,
            detected_at: now,
            session_elapsed_ms: state.timestamp.session_elapsed_ms
          ),
          duration: nil,
          entities_involved: extract_involved_entities(result, state),
          payload: build_payload(result),
          context: {}
        )
      end

      def extract_involved_entities(result, state)
        if result.to_value.is_a?(String) && result.to_value.start_with?('ent_')
          [result.to_value]
        elsif result.from_value.is_a?(String) && result.from_value.start_with?('ent_')
          [result.from_value]
        elsif state.scene.primary_entity_id
          [state.scene.primary_entity_id]
        else
          []
        end
      end

      def build_payload(result)
        payload = {}
        payload[:signal_value] = result.signal_value if result.signal_value
        payload[:threshold] = result.threshold if result.threshold
        payload[:from_value] = result.from_value if result.from_value
        payload[:to_value] = result.to_value if result.to_value
        payload[:duration_ms] = result.duration_ms if result.duration_ms
        payload
      end

      def notify_callbacks(event)
        @callbacks.each do |callback|
          callback.call(event)
        rescue StandardError => e
          Kira.logger.error("Event callback error: #{e.message}")
        end
      end
    end
  end
end
