# frozen_string_literal: true

module Kira
  module Perception
    class Client
      RECONNECT_INTERVAL = 5

      attr_reader :socket_path, :stats

      def initialize(socket_path:)
        @socket_path = socket_path
        @callbacks = []
        @running = false
        @stats = {
          frames_received: 0,
          bytes_received: 0,
          last_frame_time: nil,
          connection_errors: 0
        }
      end

      def on_frame(&block)
        @callbacks << block
      end

      def run
        @running = true

        Async do |task|
          while @running
            begin
              connect_and_receive(task)
            rescue Errno::ENOENT, Errno::ECONNREFUSED => e
              Kira.logger.warn("Perception socket not available: #{e.message}")
              Kira.logger.info("Retrying in #{RECONNECT_INTERVAL}s...")
              @stats[:connection_errors] += 1
              task.sleep(RECONNECT_INTERVAL)
            rescue StandardError => e
              Kira.logger.error("Connection error: #{e.class} - #{e.message}")
              @stats[:connection_errors] += 1
              task.sleep(RECONNECT_INTERVAL)
            end
          end
        end
      end

      def stop
        @running = false
      end

      private

      def connect_and_receive(_task)
        Kira.logger.info("Connecting to perception service at #{socket_path}")

        endpoint = Async::IO::Endpoint.unix(socket_path)

        endpoint.connect do |connection|
          Kira.logger.info('Connected to perception service')

          while @running
            frame = read_frame(connection)
            break unless frame

            @stats[:frames_received] += 1
            @stats[:last_frame_time] = Time.now

            notify_callbacks(frame)
          end
        end

        Kira.logger.info('Connection closed')
      end

      def read_frame(connection)
        length_bytes = connection.read(4)
        return nil unless length_bytes && length_bytes.bytesize == 4

        length = length_bytes.unpack1('N')
        return nil if length.zero? || length > 10_000_000

        data = connection.read(length)
        return nil unless data && data.bytesize == length

        @stats[:bytes_received] += 4 + length

        raw = MessagePack.unpack(data)
        parse_frame(raw)
      rescue MessagePack::UnpackError => e
        Kira.logger.error("Failed to unpack frame: #{e.message}")
        nil
      end

      def parse_frame(raw)
        Frame.new(
          frame_id: raw['frame_id'],
          timestamp_ms: raw['timestamp_ms'],
          detections: parse_detections(raw['detections'] || []),
          poses: parse_poses(raw['poses'] || []),
          metadata: FrameMetadata.new(
            capture_latency_ms: raw.dig('metadata', 'capture_latency_ms') || 0.0,
            inference_latency_ms: raw.dig('metadata', 'inference_latency_ms') || 0.0,
            frame_drop_count: raw.dig('metadata', 'frame_drop_count') || 0,
            width: raw.dig('metadata', 'width') || 1280,
            height: raw.dig('metadata', 'height') || 720
          )
        )
      end

      def parse_detections(raw_detections)
        raw_detections.map do |d|
          Detection.new(
            class_id: d['class_id'],
            class_name: d['class_name'],
            bbox: d['bbox'],
            confidence: d['confidence']
          )
        end
      end

      def parse_poses(raw_poses)
        raw_poses.map do |p|
          PoseEstimate.new(
            detection_idx: p['detection_idx'],
            keypoints: p['keypoints'] || {}
          )
        end
      end

      def notify_callbacks(frame)
        @callbacks.each do |callback|
          callback.call(frame)
        rescue StandardError => e
          Kira.logger.error("Callback error: #{e.message}")
        end
      end
    end
  end
end
