# frozen_string_literal: true

require 'test_helper'

class PipelineTest < Minitest::Test
  def test_processes_frames_into_world_state_and_events
    profile = Kira::Profiles::Loader.load('base')
    tracker = Kira::State::EntityTracker.new
    distiller = Kira::State::Distiller.new
    history = Kira::State::History.new
    event_engine = Kira::Events::Engine.new

    event_engine.configure_from_profile(
      enabled_categories: profile.events.enabled_categories
    )

    frames = generate_test_frames(count: 30)
    all_events = []

    frames.each do |frame|
      tracks = tracker.update(
        detections: frame.detections,
        timestamp_ms: frame.timestamp_ms,
        poses: frame.poses
      )

      next unless distiller.should_distill?(frame.frame_id)

      state = distiller.distill(
        frame: frame,
        entities: tracks,
        history: history
      )

      previous_state = history.current_state
      history.push(state)

      events = event_engine.evaluate(state, previous_state, history)
      all_events.concat(events)
    end

    assert history.size > 0
    refute_nil history.current_state

    last_state = history.current_state
    assert last_state.entities.size > 0

    assert_includes all_events.map(&:type), 'entity_appeared'
  end

  def test_therapy_profile_has_different_behavior_than_base
    therapy = Kira::Profiles::Loader.load('therapy')
    base = Kira::Profiles::Loader.load('base')

    assert_operator therapy.output.cadence_hz, :<, base.output.cadence_hz
    assert_includes therapy.output.llm.persona[:tone], 'empathetic'
  end

  def test_fitness_profile_has_high_cadence
    fitness = Kira::Profiles::Loader.load('fitness')

    assert_equal 3.0, fitness.output.cadence_hz
    assert_includes fitness.output.llm.persona[:tone], 'energetic'
  end

  private

  def generate_test_frames(count:)
    count.times.map do |i|
      has_person = i >= 5

      detections = if has_person
                     [
                       Kira::Perception::Detection.new(
                         class_id: 0,
                         class_name: 'person',
                         bbox: [0.2 + (i * 0.001), 0.2, 0.4 + (i * 0.001), 0.6],
                         confidence: 0.9
                       )
                     ]
                   else
                     []
                   end

      Kira::Perception::Frame.new(
        frame_id: i + 1,
        timestamp_ms: i * 33,
        detections: detections,
        poses: [],
        metadata: Kira::Perception::FrameMetadata.new(
          capture_latency_ms: 5.0,
          inference_latency_ms: 20.0,
          frame_drop_count: 0
        )
      )
    end
  end
end
