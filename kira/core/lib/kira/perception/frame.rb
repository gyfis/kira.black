# frozen_string_literal: true

module Kira
  module Perception
    class Detection < Dry::Struct
      attribute :class_id, Types::Integer
      attribute :class_name, Types::String
      attribute :bbox, Types::BoundingBox
      attribute :confidence, Types::Confidence

      def center
        [(bbox[0] + bbox[2]) / 2.0, (bbox[1] + bbox[3]) / 2.0]
      end

      def width
        bbox[2] - bbox[0]
      end

      def height
        bbox[3] - bbox[1]
      end

      def area
        width * height
      end
    end

    class PoseKeypoint < Dry::Struct
      attribute :x, Types::Float
      attribute :y, Types::Float
      attribute :confidence, Types::Float
    end

    class PoseEstimate < Dry::Struct
      attribute :detection_idx, Types::Integer
      attribute :keypoints, Types::Hash.map(Types::String, Types::Array.of(Types::Float))

      def keypoint(name)
        return nil unless keypoints.key?(name)

        data = keypoints[name]
        PoseKeypoint.new(x: data[0], y: data[1], confidence: data[2])
      end
    end

    class FrameMetadata < Dry::Struct
      attribute :capture_latency_ms, Types::Float
      attribute :inference_latency_ms, Types::Float
      attribute :frame_drop_count, Types::Integer.default(0)
      attribute :width, Types::Integer.default(1280)
      attribute :height, Types::Integer.default(720)
    end

    class Frame < Dry::Struct
      attribute :frame_id, Types::Integer
      attribute :timestamp_ms, Types::Timestamp
      attribute :detections, Types::Array.of(Detection).default([].freeze)
      attribute :poses, Types::Array.of(PoseEstimate).default([].freeze)
      attribute :metadata, FrameMetadata

      def person_detections
        detections.select { |d| d.class_name == 'person' }
      end

      def total_latency_ms
        metadata.capture_latency_ms + metadata.inference_latency_ms
      end
    end
  end
end
