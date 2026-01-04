# frozen_string_literal: true

module Kira
  module State
    class Track
      CONFIRM_FRAMES = 3
      LOST_THRESHOLD = 5
      DELETE_THRESHOLD = 15

      attr_reader :id, :state, :last_bbox, :first_seen_ms, :last_seen_ms,
                  :class_name, :confidence, :last_position, :velocity,
                  :pose_keypoints

      def initialize(id:, detection:, timestamp_ms:)
        @id = id
        @state = :tentative
        @class_name = detection.class_name
        @last_bbox = detection.bbox.dup
        @confidence = detection.confidence
        @first_seen_ms = timestamp_ms
        @last_seen_ms = timestamp_ms
        @missed_count = 0
        @confirmed_count = 1

        @last_position = detection.center
        @velocity = [0.0, 0.0]
        @pose_keypoints = {}
      end

      def update_with_detection(detection, timestamp_ms, pose: nil)
        old_position = @last_position
        dt = (timestamp_ms - @last_seen_ms) / 1000.0

        @last_bbox = detection.bbox.dup
        @confidence = detection.confidence
        @last_seen_ms = timestamp_ms
        @last_position = detection.center
        @missed_count = 0
        @confirmed_count += 1

        if dt > 0
          @velocity = [
            (@last_position[0] - old_position[0]) / dt,
            (@last_position[1] - old_position[1]) / dt
          ]
        end

        @pose_keypoints = pose.keypoints if pose
      end

      def mark_missed(_timestamp_ms = nil)
        @missed_count += 1
      end

      def update_lifecycle
        case @state
        when :tentative
          if @confirmed_count >= CONFIRM_FRAMES
            @state = :confirmed
          elsif @missed_count >= 3
            @state = :deleted
          end
        when :confirmed
          @state = :lost if @missed_count >= LOST_THRESHOLD
        when :lost
          if @missed_count.zero?
            @state = :confirmed
          elsif @missed_count >= DELETE_THRESHOLD
            @state = :deleted
          end
        end
      end

      def deleted?
        @state == :deleted
      end

      def confirmed?
        @state == :confirmed
      end

      def age_ms
        @last_seen_ms - @first_seen_ms
      end

      def motion_magnitude
        Math.sqrt(@velocity[0]**2 + @velocity[1]**2)
      end

      def motion_class
        mag = motion_magnitude
        if mag < 0.05
          'stationary'
        elsif mag < 0.3
          'moving'
        else
          'fast_moving'
        end
      end

      def to_entity
        Entity.new(
          id: @id,
          type: entity_type,
          track_state: @state.to_s,
          track_age_ms: age_ms,
          position: Position.new(
            bbox_normalized: @last_bbox,
            centroid_normalized: @last_position,
            confidence: @confidence
          ),
          motion: Motion.new(
            velocity_normalized: @velocity,
            motion_magnitude: motion_magnitude,
            motion_class: motion_class
          ),
          pose: if @pose_keypoints.empty?
                  nil
                else
                  Pose.new(
                    keypoints: @pose_keypoints,
                    confidence: @confidence
                  )
                end,
          confidence: @confidence,
          first_seen_ms: @first_seen_ms,
          last_seen_ms: @last_seen_ms
        )
      end

      private

      def entity_type
        case @class_name
        when 'person' then 'person'
        when 'face' then 'face'
        when 'hand' then 'hand'
        else 'object'
        end
      end
    end
  end
end
