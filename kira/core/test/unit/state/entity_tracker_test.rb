# frozen_string_literal: true

require 'test_helper'

class EntityTrackerTest < Minitest::Test
  def setup
    @tracker = Kira::State::EntityTracker.new
  end

  def test_creates_new_tentative_tracks_with_no_prior_detections
    detections = [build_detection(bbox: [0.1, 0.1, 0.3, 0.3])]

    tracks = @tracker.update(detections: detections, timestamp_ms: 0)

    assert_equal 1, tracks.size
    assert_equal :tentative, tracks.first.state
    assert tracks.first.id.start_with?('ent_')
  end

  def test_creates_multiple_tracks_for_multiple_detections
    detections = [
      build_detection(bbox: [0.1, 0.1, 0.3, 0.3]),
      build_detection(bbox: [0.5, 0.5, 0.7, 0.7])
    ]

    tracks = @tracker.update(detections: detections, timestamp_ms: 0)

    assert_equal 2, tracks.size
  end

  def test_updates_existing_track_with_matching_detection
    @tracker.update(
      detections: [build_detection(bbox: [0.1, 0.1, 0.3, 0.3])],
      timestamp_ms: 0
    )

    tracks = @tracker.update(
      detections: [build_detection(bbox: [0.12, 0.1, 0.32, 0.3])],
      timestamp_ms: 33
    )

    assert_equal 1, tracks.size
    assert_equal 'ent_1', tracks.first.id
  end

  def test_confirms_track_after_enough_matches
    5.times do |i|
      @tracker.update(
        detections: [build_detection(bbox: [0.1, 0.1, 0.3, 0.3])],
        timestamp_ms: i * 33
      )
    end

    tracks = @tracker.tracks.values
    assert_equal :confirmed, tracks.first.state
  end

  def test_marks_track_as_lost_when_detection_missing
    3.times do |i|
      @tracker.update(
        detections: [build_detection],
        timestamp_ms: i * 33
      )
    end

    track = @tracker.tracks.values.first
    assert_equal :confirmed, track.state

    6.times do |i|
      @tracker.update(detections: [], timestamp_ms: (3 + i) * 33)
    end

    assert_equal :lost, @tracker.tracks.values.first.state
  end

  def test_deletes_track_after_extended_absence
    3.times do |i|
      @tracker.update(
        detections: [build_detection],
        timestamp_ms: i * 33
      )
    end

    20.times do |i|
      @tracker.update(detections: [], timestamp_ms: (3 + i) * 33)
    end

    assert @tracker.tracks.empty?
  end

  def test_maintains_identity_based_on_iou_with_crossing_tracks
    @tracker.update(
      detections: [
        build_detection(bbox: [0.1, 0.1, 0.3, 0.3]),
        build_detection(bbox: [0.6, 0.6, 0.8, 0.8])
      ],
      timestamp_ms: 0
    )

    tracks = @tracker.update(
      detections: [
        build_detection(bbox: [0.15, 0.15, 0.35, 0.35]),
        build_detection(bbox: [0.55, 0.55, 0.75, 0.75])
      ],
      timestamp_ms: 33
    )

    assert_equal 2, tracks.size
    ids = tracks.map(&:id).sort
    assert_equal %w[ent_1 ent_2], ids
  end

  def test_active_entities_returns_entity_structs
    @tracker.update(
      detections: [build_detection],
      timestamp_ms: 0
    )

    entities = @tracker.active_entities

    assert_equal 1, entities.size
    assert_instance_of Kira::State::Entity, entities.first
  end

  def test_clear_removes_all_tracks
    @tracker.update(
      detections: [build_detection],
      timestamp_ms: 0
    )

    @tracker.clear

    assert @tracker.tracks.empty?
  end
end
