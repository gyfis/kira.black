# frozen_string_literal: true

module Kira
  module Output
    class PayloadBuilder
      def initialize(profile:)
        @profile = profile
      end

      def build(state:, events:, session_context: {})
        {
          timestamp_ms: state.timestamp.session_elapsed_ms,
          frame_id: state.timestamp.frame_id,
          events: build_events(events),
          state_summary: build_state_summary(state),
          entities_changed: build_entity_summary(state),
          conversation_signals: build_conversation_signals(state),
          session_context: session_context
        }
      end

      def build_for_llm(state:, events:, session_context: {})
        build(state: state, events: events, session_context: session_context)

        parts = []

        parts << "[Observation at #{format_time(state.timestamp.session_elapsed_ms)}]"

        if events.any?
          event_descriptions = events.map { |e| describe_event(e) }
          parts << "Events: #{event_descriptions.join('; ')}"
        end

        if state.entities.any?
          entity_descriptions = state.entities.map { |e| describe_entity(e) }
          parts << "Entities: #{entity_descriptions.join('; ')}"
        else
          parts << 'Scene: No one visible'
        end

        parts << "Recent context: #{session_context[:recent_exchanges]}" if session_context[:recent_exchanges]

        parts.join("\n")
      end

      private

      def build_events(events)
        events.map do |e|
          {
            type: e.type,
            severity: e.severity,
            timestamp_ms: e.timestamp.session_elapsed_ms,
            entities: e.entities_involved,
            payload: e.payload
          }
        end
      end

      def build_state_summary(state)
        {
          entity_count: state.entities.size,
          primary_entity_id: state.scene.primary_entity_id,
          scene_stability: state.scene.scene_stability,
          signal_quality: {
            fps: state.signal_quality.perception_fps.round(1),
            tracking_confidence: state.signal_quality.tracking_confidence
          }
        }
      end

      def build_entity_summary(state)
        state.entities.map do |entity|
          {
            id: entity.id,
            type: entity.type,
            state: entity.track_state,
            motion: entity.motion.motion_class,
            position: {
              x: entity.position.center_x.round(2),
              y: entity.position.center_y.round(2),
              area: entity.position.area.round(3)
            },
            age_ms: entity.track_age_ms,
            confidence: entity.confidence.round(2)
          }
        end
      end

      def build_conversation_signals(state)
        primary = state.primary_entity

        {
          user_present: state.entities.any?,
          user_motion_state: primary&.motion&.motion_class || 'unknown',
          attention_indicators: infer_attention(primary),
          silence_appropriate: infer_silence_appropriateness(state)
        }
      end

      def infer_attention(entity)
        return {} unless entity

        {
          facing_camera: infer_facing_camera(entity),
          engaged: entity.motion.motion_class == 'stationary'
        }
      end

      def infer_facing_camera(entity)
        return nil unless entity.position

        x = entity.position.center_x
        x > 0.2 && x < 0.8
      end

      def infer_silence_appropriateness(state)
        return true if state.entities.empty?

        primary = state.primary_entity
        return true unless primary

        primary.motion.motion_class == 'stationary'
      end

      def format_time(ms)
        total_seconds = ms / 1000
        minutes = total_seconds / 60
        seconds = total_seconds % 60
        format('%d:%02d', minutes, seconds)
      end

      def describe_event(event)
        case event.type
        when 'entity_appeared'
          'Someone appeared in view'
        when 'entity_disappeared'
          'Person left view'
        when 'motion_started'
          'Movement detected'
        when 'motion_stopped'
          'Movement stopped'
        when 'extended_stillness'
          'Extended period of stillness'
        when 'high_activity'
          'High activity detected'
        when 'exercise_pause'
          'Exercise paused'
        else
          event.type.gsub('_', ' ')
        end
      end

      def describe_entity(entity)
        position_desc = if entity.position.center_x < 0.33
                          'left side'
                        elsif entity.position.center_x > 0.66
                          'right side'
                        else
                          'center'
                        end

        motion_desc = case entity.motion.motion_class
                      when 'stationary' then 'still'
                      when 'moving' then 'moving'
                      when 'fast_moving' then 'active'
                      end

        "#{entity.type} (#{position_desc}, #{motion_desc})"
      end
    end
  end
end
