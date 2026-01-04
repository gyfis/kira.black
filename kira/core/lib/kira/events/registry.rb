# frozen_string_literal: true

module Kira
  module Events
    class EventDefinition
      attr_reader :id, :type, :category, :severity, :trigger, :cooldown_ms

      def initialize(id:, type:, category:, trigger:, severity: 'info', cooldown_ms: 1000)
        @id = id
        @type = type
        @category = category
        @severity = severity
        @trigger = trigger
        @cooldown_ms = cooldown_ms
      end
    end

    class Registry
      STANDARD_EVENTS = [
        {
          id: 'entity_appeared',
          type: 'entity_appeared',
          category: 'entity_lifecycle',
          severity: 'info',
          trigger: { type: 'lifecycle', lifecycle_event: 'appeared' },
          cooldown_ms: 500
        },
        {
          id: 'entity_disappeared',
          type: 'entity_disappeared',
          category: 'entity_lifecycle',
          severity: 'info',
          trigger: { type: 'lifecycle', lifecycle_event: 'disappeared' },
          cooldown_ms: 500
        },
        {
          id: 'motion_started',
          type: 'motion_started',
          category: 'motion_state',
          severity: 'debug',
          trigger: {
            type: 'state_change',
            signal: 'entities.0.motion.motion_class',
            from: 'stationary',
            to: 'moving'
          },
          cooldown_ms: 2000
        },
        {
          id: 'motion_stopped',
          type: 'motion_stopped',
          category: 'motion_state',
          severity: 'debug',
          trigger: {
            type: 'state_change',
            signal: 'entities.0.motion.motion_class',
            from: 'moving',
            to: 'stationary'
          },
          cooldown_ms: 2000
        }
      ].freeze

      def initialize
        @definitions = {}
        @severity_overrides = {}
      end

      def register(definition)
        event_def = case definition
                    when Hash
                      EventDefinition.new(**definition.transform_keys(&:to_sym))
                    when EventDefinition
                      definition
                    else
                      raise ArgumentError, "Invalid event definition: #{definition.class}"
                    end

        @definitions[event_def.id] = event_def
      end

      def register_standard_events(categories: nil)
        STANDARD_EVENTS.each do |event|
          next if categories && !categories.include?(event[:category])

          register(event)
        end
      end

      def get(id)
        @definitions[id]
      end

      def each(&block)
        @definitions.values.each(&block)
      end

      def for_category(category)
        @definitions.values.select { |d| d.category == category }
      end

      def override_severity(event_type, severity)
        @severity_overrides[event_type] = severity
      end

      def effective_severity(event_def)
        @severity_overrides[event_def.type] || event_def.severity
      end

      def size
        @definitions.size
      end

      def clear
        @definitions.clear
        @severity_overrides.clear
      end
    end
  end
end
