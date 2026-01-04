# frozen_string_literal: true

require 'test_helper'

class OrchestratorTest < Minitest::Test
  def setup
    @session_id = "kira:test-#{Time.now.to_i}"
  end

  def test_orchestrator_initializes_with_session_id
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    assert_equal @session_id, orchestrator.session_id
    assert_instance_of Kira::OpenCode::Bridge, orchestrator.bridge
  end

  def test_orchestrator_starts_and_stops
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    orchestrator.start
    assert orchestrator.running

    orchestrator.stop
    refute orchestrator.running
  end

  def test_on_speak_callback_is_called_when_bridge_returns_response
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:should_speak?, true, observation: String, context: Hash)
    mock_bridge.expect(:send_observation, 'Hello! I can see you.', [String], type: :visual)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_visual('Person sitting at desk')

    mock_bridge.verify
    assert_equal 1, spoken_responses.length
    assert_equal 'Hello! I can see you.', spoken_responses.first
  end

  def test_on_observation_callback_is_called_for_visual_input
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    observations = []
    orchestrator.on_observation { |type, content| observations << [type, content] }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:should_speak?, false, observation: String, context: Hash)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_visual('Empty room')

    assert_equal 1, observations.length
    assert_equal :visual, observations.first[0]
    assert_equal 'Empty room', observations.first[1]
  end

  def test_voice_input_always_gets_response
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, 'I heard you say hello!', [String], type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_voice('Hello Kira')

    mock_bridge.verify
    assert_equal 1, spoken_responses.length
    assert_equal 'I heard you say hello!', spoken_responses.first
  end

  def test_silence_responses_are_not_spoken
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, '[SILENCE]', [String], type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_voice('Are you there?')

    mock_bridge.verify
    assert_empty spoken_responses
  end

  def test_wait_response_is_not_spoken
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, 'WAIT', [String], type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_voice('Hello')

    mock_bridge.verify
    assert_empty spoken_responses
  end

  def test_context_includes_seconds_since_spoke
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    orchestrator.start

    context_captured = nil
    mock_bridge = Minitest::Mock.new

    mock_bridge.expect(:should_speak?, true) do |observation:, context:|
      context_captured = context
      true
    end
    mock_bridge.expect(:send_observation, 'Test', [String], type: :visual)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_visual('Scene description')

    assert_includes context_captured.keys, :seconds_since_spoke
    assert_includes context_captured.keys, :session_elapsed
  end

  def test_seconds_since_spoke_updates_after_speaking
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    orchestrator.start

    # Initially should be infinity (never spoke)
    assert_equal Float::INFINITY, orchestrator.seconds_since_spoke

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, 'Hello!', [String], type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_voice('Hi')

    # After speaking, should be close to 0
    assert_operator orchestrator.seconds_since_spoke, :<, 1
  end

  def test_event_processing_uses_should_speak_decision
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:should_speak?, false, observation: String, context: Hash)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_event(:entity_appeared, 'Person entered')

    mock_bridge.verify
    assert_empty spoken_responses
  end

  def test_event_processing_speaks_when_should_speak_returns_true
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:should_speak?, true, observation: String, context: Hash)
    mock_bridge.expect(:send_observation, 'Someone new!', [String], type: :event)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_event(:entity_appeared, 'Person entered')

    mock_bridge.verify
    assert_equal 1, spoken_responses.length
    assert_equal 'Someone new!', spoken_responses.first
  end

  def test_empty_response_is_not_spoken
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, '   ', [String], type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_voice('Hello')

    assert_empty spoken_responses
  end

  def test_nil_response_is_not_spoken
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_responses = []
    orchestrator.on_speak { |response| spoken_responses << response }

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, nil, [String], type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    orchestrator.process_voice('Hello')

    assert_empty spoken_responses
  end
end

class OrchestratorEndToEndTest < Minitest::Test
  def setup
    @session_id = "kira:e2e-test-#{Time.now.to_i}"
  end

  def test_full_visual_to_speech_flow
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    visual_observations = []
    spoken_texts = []

    orchestrator.on_observation do |type, content|
      visual_observations << content if type == :visual
    end

    orchestrator.on_speak do |text|
      spoken_texts << text
    end

    orchestrator.start

    mock_bridge = Minitest::Mock.new

    mock_bridge.expect(:should_speak?, true, observation: String, context: Hash)
    mock_bridge.expect(:send_observation, 'I see you waving! Hello there!', [String], type: :visual)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    # Simulate: Camera captures frame -> Moondream describes -> Orchestrator processes
    orchestrator.process_visual('Person at desk, waving at camera with a smile')

    mock_bridge.verify

    assert_equal ['Person at desk, waving at camera with a smile'], visual_observations
    assert_equal ['I see you waving! Hello there!'], spoken_texts
  end

  def test_full_voice_to_speech_flow
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    voice_observations = []
    spoken_texts = []

    orchestrator.on_observation do |type, content|
      voice_observations << content if type == :voice
    end

    orchestrator.on_speak do |text|
      spoken_texts << text
    end

    orchestrator.start

    mock_bridge = Minitest::Mock.new
    mock_bridge.expect(:send_observation, 'Your workspace looks great! The plants add a nice touch.', [String],
                       type: :voice)

    orchestrator.instance_variable_set(:@bridge, mock_bridge)

    # Simulate: Whisper transcribes -> Orchestrator processes
    orchestrator.process_voice('Hey Kira, what do you think of my desk setup?')

    mock_bridge.verify

    assert_equal ['Hey Kira, what do you think of my desk setup?'], voice_observations
    assert_equal ['Your workspace looks great! The plants add a nice touch.'], spoken_texts
  end

  def test_multiple_observations_accumulate_context
    orchestrator = Kira::Orchestrator.new(session_id: @session_id)

    spoken_texts = []
    orchestrator.on_speak { |text| spoken_texts << text }

    orchestrator.start

    # First observation (visual) - choose not to speak
    mock_bridge1 = Minitest::Mock.new
    mock_bridge1.expect(:should_speak?, false, observation: String, context: Hash)
    orchestrator.instance_variable_set(:@bridge, mock_bridge1)

    orchestrator.process_visual('Person typing on keyboard')
    mock_bridge1.verify
    assert_empty spoken_texts

    # Second observation (voice) - user asks question, always respond
    mock_bridge2 = Minitest::Mock.new
    mock_bridge2.expect(:send_observation, "I see you're focused on your work!", [String], type: :voice)
    orchestrator.instance_variable_set(:@bridge, mock_bridge2)

    orchestrator.process_voice('Kira, are you watching?')
    mock_bridge2.verify
    assert_equal 1, spoken_texts.length

    # Verify context shows we spoke recently
    assert_operator orchestrator.seconds_since_spoke, :<, 1
  end
end
