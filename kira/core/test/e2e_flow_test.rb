# frozen_string_literal: true

require_relative 'test_helper'

# End-to-end flow tests that verify the complete Kira pipeline
# These tests mock the external dependencies (OpenCode, Python perception)
# but verify the full data flow through all components.
class E2EFlowTest < Minitest::Test
  def setup
    @orchestrator = Kira::Orchestrator.new(
      session_id: 'e2e-test',
      enable_perception: false,
      persona: 'Test persona'
    )
  end

  def teardown
    @orchestrator.stop if @orchestrator.running
  end

  # === Full Visual Flow Tests ===

  def test_visual_observation_to_speech_flow
    # This tests: visual data -> bridge.should_speak? -> bridge.send_observation -> TTS callback

    bridge = @orchestrator.bridge

    # Mock the bridge methods
    should_speak_called = false
    send_observation_called = false

    bridge.define_singleton_method(:should_speak?) do |observation:, context:, persona:|
      should_speak_called = true
      # Verify correct data passed through
      raise 'Missing observation' unless observation.include?('happy')
      raise 'Missing context' unless context[:session_elapsed]

      { decision: :speak, reasoning: 'User looks happy' }
    end

    bridge.define_singleton_method(:send_observation) do |_msg, type:|
      send_observation_called = true
      raise 'Wrong type' unless type == :visual

      'You look happy today!'
    end

    # Track outputs
    spoken_text = nil
    decision_info = nil

    @orchestrator.on_speak { |text| spoken_text = text }
    @orchestrator.on_decision { |info| decision_info = info }
    @orchestrator.instance_variable_set(:@start_time, Time.now)

    # Simulate visual event
    visual_data = {
      emotion: 'happy',
      description: 'Person looks happy and engaged',
      inference_ms: 150,
      is_full_analysis: false
    }

    @orchestrator.send(:process_visual, visual_data)

    # Verify full flow
    assert should_speak_called, 'should_speak? was not called'
    assert send_observation_called, 'send_observation was not called'
    assert_equal 'You look happy today!', spoken_text
    assert_equal :speak, decision_info[:decision]
    assert_equal 'happy', decision_info[:emotion]
  end

  def test_visual_observation_wait_flow
    # Test that WAIT decisions don't trigger speech

    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:should_speak?) do |**_|
      { decision: :wait, reasoning: 'Nothing interesting' }
    end

    spoken = false
    @orchestrator.on_speak { spoken = true }
    @orchestrator.instance_variable_set(:@start_time, Time.now)

    @orchestrator.send(:process_visual, { emotion: 'neutral' })

    refute spoken, 'Should not speak on WAIT decision'
  end

  # === Full Voice Flow Tests ===

  def test_voice_input_to_speech_flow
    # This tests: voice transcription -> bridge.send_observation -> TTS callback

    bridge = @orchestrator.bridge

    received_message = nil
    bridge.define_singleton_method(:send_observation) do |msg, type:|
      received_message = msg
      raise 'Wrong type' unless type == :voice

      'Hello! Nice to meet you!'
    end

    spoken_text = nil
    decision_info = nil

    @orchestrator.on_speak { |text| spoken_text = text }
    @orchestrator.on_decision { |info| decision_info = info }
    @orchestrator.instance_variable_set(:@start_time, Time.now)

    # Simulate voice event (decision callback is emitted before processing)
    @orchestrator.send(:emit_voice_decision, 'Hello Kira')
    @orchestrator.send(:process_voice, 'Hello Kira')

    assert_equal 'Hello Kira', received_message
    assert_equal 'Hello! Nice to meet you!', spoken_text
    assert_equal :voice, decision_info[:type]
    assert_equal :speak, decision_info[:decision]
  end

  # === Event Queue Flow Tests ===

  def test_event_queue_processes_events_in_order
    bridge = @orchestrator.bridge
    processed_order = []

    bridge.define_singleton_method(:should_speak?) do |observation:, **_|
      processed_order << "visual:#{observation}"
      { decision: :wait, reasoning: '' }
    end

    bridge.define_singleton_method(:send_observation) do |msg, **_|
      processed_order << "voice:#{msg}"
      nil
    end

    @orchestrator.instance_variable_set(:@running, true)
    @orchestrator.instance_variable_set(:@start_time, Time.now)

    # Queue events
    @orchestrator.send(:queue_event, :visual, { description: 'event1' })
    @orchestrator.send(:queue_event, :voice, 'event2')
    @orchestrator.send(:queue_event, :visual, { description: 'event3' })

    # Process all events
    queue = @orchestrator.instance_variable_get(:@event_queue)
    3.times do
      event = queue.pop(true)
      case event[:type]
      when :visual
        @orchestrator.send(:process_visual, event[:data])
      when :voice
        @orchestrator.send(:process_voice, event[:data])
      end
    end

    assert_equal ['visual:event1', 'voice:event2', 'visual:event3'], processed_order
  end

  # === Response Filtering Flow Tests ===

  def test_silence_markers_filtered_throughout_flow
    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:send_observation) { |_msg, **_| '[SILENCE]' }

    spoken = false
    @orchestrator.on_speak { spoken = true }

    @orchestrator.send(:process_voice, 'Hello')

    refute spoken, 'Should filter [SILENCE] responses'
  end

  def test_wait_response_filtered_throughout_flow
    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:send_observation) { |_msg, **_| 'WAIT' }

    spoken = false
    @orchestrator.on_speak { spoken = true }

    @orchestrator.send(:process_voice, 'Hello')

    refute spoken, 'Should filter WAIT responses'
  end

  # === State Update Flow Tests ===

  def test_speaking_updates_last_spoke_at
    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:send_observation) { |_msg, **_| 'Hello!' }

    assert_nil @orchestrator.instance_variable_get(:@last_spoke_at)

    @orchestrator.send(:process_voice, 'Hi')

    refute_nil @orchestrator.instance_variable_get(:@last_spoke_at)
  end

  def test_visual_updates_last_emotion
    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:should_speak?) { |**_| { decision: :wait, reasoning: '' } }

    @orchestrator.instance_variable_set(:@start_time, Time.now)

    @orchestrator.send(:process_visual, { emotion: 'excited' })

    assert_equal 'excited', @orchestrator.instance_variable_get(:@last_emotion)
  end

  def test_context_includes_last_emotion
    bridge = @orchestrator.bridge
    received_context = nil

    bridge.define_singleton_method(:should_speak?) do |context:, **_|
      received_context = context
      { decision: :wait, reasoning: '' }
    end

    @orchestrator.instance_variable_set(:@start_time, Time.now)
    @orchestrator.instance_variable_set(:@last_emotion, 'curious')

    @orchestrator.send(:process_visual, { emotion: 'happy' })

    assert_equal 'curious', received_context[:last_emotion]
  end

  # === Perception Integration Tests ===

  def test_perception_speak_called_on_response
    mock_perception = Minitest::Mock.new
    mock_perception.expect :speak, nil, ['Hello there!']

    @orchestrator.instance_variable_set(:@perception, mock_perception)

    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:send_observation) { |_msg, **_| 'Hello there!' }

    @orchestrator.send(:process_voice, 'Hi')

    mock_perception.verify
  end

  def test_perception_not_called_when_nil
    @orchestrator.instance_variable_set(:@perception, nil)

    bridge = @orchestrator.bridge
    bridge.define_singleton_method(:send_observation) { |_msg, **_| 'Hello!' }

    # Should not raise
    @orchestrator.send(:process_voice, 'Hi')
  end
end

class E2EUnifiedClientFlowTest < Minitest::Test
  def setup
    @client = Kira::Perception::UnifiedClient.new
  end

  # Test the complete event flow from Python output to Ruby callbacks

  def test_visual_event_flow
    received_data = nil
    @client.on_visual { |data| received_data = data }

    # Simulate Python output line
    python_output = '{"type":"visual","data":{"emotion":"happy","description":"Person smiling","inference_ms":150,"is_full_analysis":false},"timestamp":1234567890.0}'

    @client.send(:process_event, python_output)

    assert_equal 'happy', received_data[:emotion]
    assert_equal 'Person smiling', received_data[:description]
    assert_equal 150, received_data[:inference_ms]
    assert_equal false, received_data[:is_full_analysis]
  end

  def test_voice_event_flow
    received_text = nil
    @client.on_voice { |text| received_text = text }

    python_output = '{"type":"voice","data":{"text":"Hello Kira","language":"en","latency_ms":350}}'

    @client.send(:process_event, python_output)

    assert_equal 'Hello Kira', received_text
  end

  def test_interrupt_event_flow
    @client.instance_variable_set(:@speaking, true)

    received_text = nil
    @client.on_interrupt { |text| received_text = text }

    python_output = '{"type":"interrupt","data":{"text":"stop"}}'

    @client.send(:process_event, python_output)

    assert_equal 'stop', received_text
    refute @client.speaking?
  end

  def test_error_event_flow
    received_message = nil
    @client.on_error { |msg| received_message = msg }

    python_output = '{"type":"error","data":{"message":"Camera failed to open"}}'

    @client.send(:process_event, python_output)

    assert_equal 'Camera failed to open', received_message
  end

  def test_command_to_python_flow
    stdin = StringIO.new
    @client.instance_variable_set(:@stdin, stdin)

    @client.speak('Hello world!')

    stdin.rewind
    line = stdin.read
    parsed = JSON.parse(line)

    assert_equal 'speak', parsed['command']
    assert_equal 'Hello world!', parsed['text']
    assert @client.speaking?
  end

  def test_interrupt_command_flow
    stdin = StringIO.new
    @client.instance_variable_set(:@stdin, stdin)
    @client.instance_variable_set(:@speaking, true)

    @client.interrupt

    stdin.rewind
    line = stdin.read
    parsed = JSON.parse(line)

    assert_equal 'interrupt', parsed['command']
    refute @client.speaking?
  end
end

class E2EBridgeFlowTest < Minitest::Test
  # Test the complete OpenCode bridge flow with mocked responses

  def test_should_speak_flow_with_json_response
    bridge = Kira::OpenCode::Bridge.new('test')

    # Mock run to return JSON format (first call)
    bridge.define_singleton_method(:run) do |_msg, **_opts|
      "SPEAK\nUser looks engaged and curious"
    end

    result = bridge.should_speak?(
      observation: 'Person looking at screen intently',
      context: { seconds_since_spoke: 30, session_elapsed: 120 }
    )

    assert_equal :speak, result[:decision]
    assert_includes result[:reasoning], 'engaged'
  end

  def test_session_continuity_flow
    bridge = Kira::OpenCode::Bridge.new('test')

    # Simulate first call with JSON response
    json_response = <<~JSON
      {"type":"step_start","sessionID":"ses_abc123"}
      {"type":"text","sessionID":"ses_abc123","part":{"text":"Hello!"}}
      {"type":"step_finish","sessionID":"ses_abc123"}
    JSON

    result = bridge.send(:parse_response, json_response)

    assert_equal 'Hello!', result
    assert bridge.session_initialized?
    assert_equal 'ses_abc123', bridge.instance_variable_get(:@opencode_session_id)
  end

  def test_subsequent_calls_use_session_id
    bridge = Kira::OpenCode::Bridge.new('test')
    bridge.instance_variable_set(:@opencode_session_id, 'ses_existing')

    cmd = bridge.send(:build_command, 'test message')

    assert_includes cmd, '--session'
    assert_includes cmd, 'ses_existing'
    refute_includes cmd, '--title'
    refute_includes cmd, '--format'
  end
end
