# frozen_string_literal: true

module Kira
  module State
    class Distiller
      OUTPUT_RATE_HZ = 5

      def initialize(session_start_time: nil)
        @session_start_time = session_start_time || Time.now
        @last_distill_time = 0
        @frame_count = 0
        @frames_per_sample = 30 / OUTPUT_RATE_HZ
      end

      def distill(frame:, entities:, history: nil)
        @frame_count += 1

        timestamp = Kira::State::StateTimestamp.new(
          wall_clock: Time.now,
          session_elapsed_ms: frame.timestamp_ms,
          frame_id: frame.frame_id
        )

        entity_structs = entities.map(&:to_entity)
        primary_entity = select_primary_entity(entity_structs)

        WorldState.new(
          timestamp: timestamp,
          scene: build_scene_state(entity_structs, primary_entity, history),
          entities: entity_structs,
          signal_quality: build_signal_quality(frame, history)
        )
      end

      def should_distill?(frame_id)
        frame_id % @frames_per_sample == 0
      end

      def reset
        @frame_count = 0
        @last_distill_time = 0
        @session_start_time = Time.now
      end

      private

      def select_primary_entity(entities)
        confirmed = entities.select(&:confirmed?)
        return nil if confirmed.empty?

        confirmed.max_by do |e|
          score = e.confidence * 0.4
          score += e.position.area * 0.3
          score += (1.0 - (e.position.center_x - 0.5).abs) * 0.2
          score += (e.track_age_ms / 10_000.0).clamp(0, 1) * 0.1
          score
        end
      end

      def build_scene_state(entities, primary_entity, history)
        stability = calculate_scene_stability(entities, history)

        SceneState.new(
          entity_count: entities.size,
          primary_entity_id: primary_entity&.id,
          scene_stability: stability
        )
      end

      def calculate_scene_stability(entities, history)
        return 1.0 if history.nil? || history.empty?

        prev_state = history.previous_state
        return 1.0 if prev_state.nil?

        current_ids = Set.new(entities.map(&:id))
        prev_ids = Set.new(prev_state.entities.map(&:id))

        overlap = (current_ids & prev_ids).size
        total = (current_ids | prev_ids).size

        return 1.0 if total.zero?

        overlap.to_f / total
      end

      def build_signal_quality(frame, history)
        frame_drop_rate = if frame.metadata.frame_drop_count.positive? && history && history.size > 10
                            frame.metadata.frame_drop_count.to_f / (history.size * 6)
                          else
                            0.0
                          end

        SignalQuality.new(
          perception_fps: calculate_fps(history),
          tracking_confidence: 1.0,
          frame_drop_rate: frame_drop_rate.clamp(0.0, 1.0)
        )
      end

      def calculate_fps(history)
        return 30.0 if history.nil? || history.size < 2

        duration_ms = history.duration_ms
        return 30.0 if duration_ms.zero?

        samples = history.size
        (samples * 1000.0 / duration_ms).clamp(1.0, 60.0)
      end
    end
  end
end
