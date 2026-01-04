# frozen_string_literal: true

module Kira
  module State
    class StateTimestamp < Dry::Struct
      attribute :wall_clock, Types::Time
      attribute :session_elapsed_ms, Types::Integer
      attribute :frame_id, Types::Integer
    end

    class Position < Dry::Struct
      attribute :bbox_normalized, Types::BoundingBox
      attribute :centroid_normalized, Types::Centroid
      attribute :confidence, Types::Coercible::Float.default(0.9)

      def area
        (bbox_normalized[2] - bbox_normalized[0]) *
          (bbox_normalized[3] - bbox_normalized[1])
      end

      def center_x
        centroid_normalized[0]
      end

      def center_y
        centroid_normalized[1]
      end
    end

    class Motion < Dry::Struct
      attribute :velocity_normalized, Types::Centroid.default([0.0, 0.0].freeze)
      attribute :motion_magnitude, Types::Coercible::Float.default(0.0)
      attribute :motion_class, Types::String.default('stationary')

      def moving?
        motion_class != 'stationary'
      end
    end

    class Pose < Dry::Struct
      attribute :keypoints, Types::Hash.default({}.freeze)
      attribute :confidence, Types::Coercible::Float.default(0.0)

      def keypoint(name)
        keypoints[name]
      end
    end

    class Entity < Dry::Struct
      attribute :id, Types::String
      attribute :type, Types::String.default('person')
      attribute :track_state, Types::String.default('tentative')
      attribute :track_age_ms, Types::Integer
      attribute :position, Position
      attribute :motion, Motion
      attribute :pose, Pose.optional
      attribute :confidence, Types::Coercible::Float.default(0.9)
      attribute :first_seen_ms, Types::Integer
      attribute :last_seen_ms, Types::Integer

      def confirmed?
        track_state == 'confirmed'
      end

      def lost?
        track_state == 'lost'
      end
    end

    class SceneState < Dry::Struct
      attribute :entity_count, Types::Integer.default(0)
      attribute :primary_entity_id, Types::String.optional
      attribute :scene_stability, Types::Coercible::Float.default(1.0)
    end

    class SignalQuality < Dry::Struct
      attribute :perception_fps, Types::Coercible::Float.default(30.0)
      attribute :tracking_confidence, Types::Coercible::Float.default(1.0)
      attribute :frame_drop_rate, Types::Coercible::Float.default(0.0)
    end

    class WorldState < Dry::Struct
      attribute :version, Types::String.default('1.0.0')
      attribute :timestamp, StateTimestamp
      attribute :scene, SceneState
      attribute :entities, Types::Array.of(Entity).default([].freeze)
      attribute :signal_quality, SignalQuality

      def entity(id)
        entities.find { |e| e.id == id }
      end

      def primary_entity
        return nil unless scene.primary_entity_id

        entity(scene.primary_entity_id)
      end

      def person_entities
        entities.select { |e| e.type == 'person' }
      end

      def confirmed_entities
        entities.select(&:confirmed?)
      end

      def to_summary
        {
          timestamp_ms: timestamp.session_elapsed_ms,
          entity_count: entities.size,
          primary_entity_id: scene.primary_entity_id,
          entities: entities.map do |e|
            {
              id: e.id,
              type: e.type,
              state: e.track_state,
              motion: e.motion.motion_class,
              confidence: e.confidence.round(2)
            }
          end
        }
      end
    end
  end
end
