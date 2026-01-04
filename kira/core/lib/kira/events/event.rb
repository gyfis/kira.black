# frozen_string_literal: true

module Kira
  module Events
    class EventTimestamp < Dry::Struct
      attribute :occurred_at, Types::Time
      attribute :detected_at, Types::Time
      attribute :session_elapsed_ms, Types::Integer

      def detection_lag_ms
        ((detected_at - occurred_at) * 1000).to_i
      end
    end

    class EventDuration < Dry::Struct
      attribute :started_at, Types::Time
      attribute :ended_at, Types::Time.optional
      attribute :is_ongoing, Types::Bool.default(false)

      def duration_ms
        return nil if is_ongoing

        ((ended_at - started_at) * 1000).to_i
      end
    end

    class Event < Dry::Struct
      attribute :event_id, Types::String
      attribute :type, Types::String
      attribute :category, Types::String
      attribute :severity, Types::Severity
      attribute :confidence, Types::Coercible::Float.default(1.0)
      attribute :timestamp, EventTimestamp
      attribute :duration, EventDuration.optional
      attribute :entities_involved, Types::Array.of(Types::String).default([].freeze)
      attribute :payload, Types::Hash.default({}.freeze)
      attribute :context, Types::Hash.default({}.freeze)

      def active?
        duration&.is_ongoing == true
      end

      def high_priority?
        %w[warning alert].include?(severity)
      end

      def to_h
        {
          event_id: event_id,
          type: type,
          category: category,
          severity: severity,
          confidence: confidence,
          timestamp_ms: timestamp.session_elapsed_ms,
          entities_involved: entities_involved,
          payload: payload
        }
      end
    end
  end
end
