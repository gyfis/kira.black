# frozen_string_literal: true

module Kira
  module State
    class EntityTracker
      IOU_THRESHOLD = 0.3
      MAX_TRACKS = 20

      attr_reader :tracks

      def initialize
        @tracks = {}
        @next_id = 0
      end

      def update(detections:, timestamp_ms:, poses: [])
        return handle_no_detections(timestamp_ms) if detections.empty?

        active_tracks = @tracks.values.reject(&:deleted?)

        return detections.map { |d| create_track(d, timestamp_ms, poses) } if active_tracks.empty?

        cost_matrix = build_cost_matrix(active_tracks, detections)
        assignments = hungarian_solve(cost_matrix, active_tracks, detections)

        process_assignments(
          assignments, active_tracks, detections,
          cost_matrix, timestamp_ms, poses
        )

        @tracks.each_value(&:update_lifecycle)
        @tracks.delete_if { |_, t| t.deleted? }

        @tracks.values.reject(&:deleted?)
      end

      def active_entities
        @tracks.values.reject(&:deleted?).map(&:to_entity)
      end

      def get(entity_id)
        @tracks[entity_id]
      end

      def clear
        @tracks.clear
        @next_id = 0
      end

      private

      def handle_no_detections(timestamp_ms)
        @tracks.each_value { |t| t.mark_missed(timestamp_ms) }
        @tracks.each_value(&:update_lifecycle)
        @tracks.delete_if { |_, t| t.deleted? }
        []
      end

      def create_track(detection, timestamp_ms, poses)
        id = "ent_#{@next_id += 1}"
        pose = find_matching_pose(poses, @tracks.size)

        track = Track.new(
          id: id,
          detection: detection,
          timestamp_ms: timestamp_ms
        )
        track.update_with_detection(detection, timestamp_ms, pose: pose) if pose

        @tracks[id] = track
        track
      end

      def find_matching_pose(poses, detection_idx)
        poses.find { |p| p.detection_idx == detection_idx }
      end

      def build_cost_matrix(tracks, detections)
        tracks.map do |track|
          detections.map do |detection|
            1.0 - bbox_iou(track.last_bbox, detection.bbox)
          end
        end
      end

      def hungarian_solve(cost_matrix, _tracks, _detections)
        return {} if cost_matrix.empty? || cost_matrix[0].empty?

        assignments = {}
        n_tracks = cost_matrix.size
        n_dets = cost_matrix[0].size

        used_dets = Set.new

        n_tracks.times do |t_idx|
          best_det = nil
          best_cost = Float::INFINITY

          n_dets.times do |d_idx|
            next if used_dets.include?(d_idx)

            cost = cost_matrix[t_idx][d_idx]
            if cost < best_cost
              best_cost = cost
              best_det = d_idx
            end
          end

          if best_det && best_cost < (1.0 - IOU_THRESHOLD)
            assignments[t_idx] = best_det
            used_dets << best_det
          end
        end

        assignments
      end

      def process_assignments(assignments, tracks, detections, _cost_matrix, timestamp_ms, poses)
        matched_detections = Set.new

        assignments.each do |track_idx, det_idx|
          track = tracks[track_idx]
          detection = detections[det_idx]
          pose = find_matching_pose(poses, det_idx)

          track.update_with_detection(detection, timestamp_ms, pose: pose)
          matched_detections << det_idx
        end

        tracks.each_with_index do |track, idx|
          next if assignments.key?(idx)

          track.mark_missed(timestamp_ms)
        end

        detections.each_with_index do |detection, idx|
          next if matched_detections.include?(idx)
          next if @tracks.size >= MAX_TRACKS

          create_track(detection, timestamp_ms, poses)
        end

        @tracks.values.reject(&:deleted?)
      end

      def bbox_iou(bbox1, bbox2)
        x1 = [bbox1[0], bbox2[0]].max
        y1 = [bbox1[1], bbox2[1]].max
        x2 = [bbox1[2], bbox2[2]].min
        y2 = [bbox1[3], bbox2[3]].min

        return 0.0 if x2 < x1 || y2 < y1

        intersection = (x2 - x1) * (y2 - y1)
        area1 = (bbox1[2] - bbox1[0]) * (bbox1[3] - bbox1[1])
        area2 = (bbox2[2] - bbox2[0]) * (bbox2[3] - bbox2[1])
        union = area1 + area2 - intersection

        return 0.0 if union <= 0

        intersection / union
      end
    end
  end
end
