# frozen_string_literal: true

require 'test_helper'

class EngineTest < Minitest::Test
  def setup
    @registry = Kira::Events::Registry.new
    @engine = Kira::Events::Engine.new(registry: @registry)
    @registry.register_standard_events
    @history = Kira::State::History.new
  end

  def test_fires_entity_appeared_when_entity_is_new
    previous_state = build_world_state(elapsed_ms: 0, entities: [])
    current_state = build_world_state(
      elapsed_ms: 200,
      entities: [build_entity(id: 'ent_1')]
    )

    events = @engine.evaluate(current_state, previous_state, @history)

    assert_equal 1, events.size
    assert_equal 'entity_appeared', events.first.type
  end

  def test_fires_entity_disappeared_when_entity_is_gone
    previous_state = build_world_state(
      elapsed_ms: 0,
      entities: [build_entity(id: 'ent_1')]
    )
    current_state = build_world_state(elapsed_ms: 200, entities: [])

    events = @engine.evaluate(current_state, previous_state, @history)

    assert_equal 1, events.size
    assert_equal 'entity_disappeared', events.first.type
  end

  def test_respects_cooldown_period
    previous_state = build_world_state(elapsed_ms: 0, entities: [])
    current_state = build_world_state(
      elapsed_ms: 200,
      entities: [build_entity(id: 'ent_1')]
    )

    @engine.evaluate(current_state, previous_state, @history)

    state2 = build_world_state(elapsed_ms: 400, entities: [])
    state3 = build_world_state(
      elapsed_ms: 600,
      entities: [build_entity(id: 'ent_2')]
    )

    @engine.evaluate(state2, current_state, @history)
    events = @engine.evaluate(state3, state2, @history)

    appeared_events = events.select { |e| e.type == 'entity_appeared' }
    assert appeared_events.empty?
  end

  def test_fires_motion_started_when_motion_begins
    previous_state = build_world_state(
      elapsed_ms: 0,
      entities: [build_entity(motion_class: 'stationary')]
    )
    current_state = build_world_state(
      elapsed_ms: 200,
      entities: [build_entity(motion_class: 'moving')]
    )

    events = @engine.evaluate(current_state, previous_state, @history)

    motion_events = events.select { |e| e.type == 'motion_started' }
    assert_equal 1, motion_events.size
  end

  def test_configure_from_profile_registers_events
    @engine.configure_from_profile(
      enabled_categories: ['entity_lifecycle'],
      custom_events: [
        {
          id: 'custom_test',
          type: 'custom_test',
          category: 'test',
          trigger: { type: 'threshold', signal: 'entities.size', condition: '> 2' }
        }
      ]
    )

    refute_nil @engine.registry.get('entity_appeared')
    refute_nil @engine.registry.get('custom_test')
  end

  def test_on_event_calls_registered_callbacks
    received_events = []
    @engine.on_event { |e| received_events << e }

    previous_state = build_world_state(elapsed_ms: 0, entities: [])
    current_state = build_world_state(
      elapsed_ms: 200,
      entities: [build_entity]
    )

    @engine.evaluate(current_state, previous_state, @history)

    assert_equal 1, received_events.size
  end

  def test_reset_clears_trigger_states_and_cooldowns
    previous_state = build_world_state(elapsed_ms: 0, entities: [])
    current_state = build_world_state(
      elapsed_ms: 200,
      entities: [build_entity]
    )

    @engine.evaluate(current_state, previous_state, @history)
    @engine.reset

    events = @engine.evaluate(current_state, previous_state, @history)
    assert_equal 1, events.size
  end
end
