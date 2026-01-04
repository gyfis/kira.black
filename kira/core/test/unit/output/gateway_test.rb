# frozen_string_literal: true

require 'test_helper'

class GatewayTest < Minitest::Test
  def setup
    @profile = Kira::Profiles::Loader.load('base')
    @gateway = Kira::Output::Gateway.new(profile: @profile)
  end

  def test_respects_cadence
    state1 = build_world_state(elapsed_ms: 0, entities: [build_entity])
    state2 = build_world_state(elapsed_ms: 100, entities: [build_entity])
    state3 = build_world_state(elapsed_ms: 600, entities: [build_entity])

    # Force output first to set the baseline
    output1 = @gateway.force_output(state: state1, events: [])

    # This should be suppressed by cadence (no events, no speak)
    output2 = @gateway.process(state: state2, events: [])

    # This should pass cadence (base profile is 2Hz = 500ms)
    output3 = @gateway.force_output(state: state3, events: [])

    refute_nil output1
    assert_nil output2
    refute_nil output3
  end

  def test_force_output_returns_output_with_payload
    state = build_world_state(elapsed_ms: 0, entities: [build_entity])

    output = @gateway.force_output(state: state, events: [])

    refute_nil output
    refute_nil output[:payload]
    refute_nil output[:llm_prompt]
    assert output[:decision]
  end

  def test_force_output_ignores_cadence
    state1 = build_world_state(elapsed_ms: 0, entities: [build_entity])
    state2 = build_world_state(elapsed_ms: 100, entities: [build_entity])

    @gateway.force_output(state: state1, events: [])
    output = @gateway.force_output(state: state2, events: [])

    refute_nil output
    assert output[:forced]
  end

  def test_stats_are_tracked_on_force_output
    state = build_world_state(elapsed_ms: 0, entities: [build_entity])

    @gateway.force_output(state: state, events: [])

    assert_equal 1, @gateway.stats[:outputs_emitted]
  end

  def test_callbacks_are_called_on_force_output
    received_outputs = []
    @gateway.on_output { |o| received_outputs << o }

    state = build_world_state(elapsed_ms: 0, entities: [build_entity])

    @gateway.force_output(state: state, events: [])

    assert_equal 1, received_outputs.size
  end

  def test_high_priority_events_trigger_output
    state = build_world_state(elapsed_ms: 0, entities: [build_entity])
    event = create_high_priority_event

    output = @gateway.process(state: state, events: [event])

    refute_nil output
  end

  private

  def create_high_priority_event
    now = Time.now
    Kira::Events::Event.new(
      event_id: 'evt_1',
      type: 'entity_appeared',
      category: 'entity_lifecycle',
      severity: 'warning',
      confidence: 1.0,
      timestamp: Kira::Events::EventTimestamp.new(
        occurred_at: now,
        detected_at: now,
        session_elapsed_ms: 0
      ),
      duration: nil,
      entities_involved: ['ent_1'],
      payload: {},
      context: {}
    )
  end
end
