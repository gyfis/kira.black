# frozen_string_literal: true

require_relative 'test_helper'

class UnifiedClientTest < Minitest::Test
  def setup
    @client = Kira::Perception::UnifiedClient.new
  end

  # === Initialization Tests ===

  def test_client_initializes
    assert_instance_of Kira::Perception::UnifiedClient, @client
    refute @client.running
    refute @client.speaking?
  end

  # === Callback Registration Tests ===

  def test_on_visual_callback_registers
    @client.on_visual { |_data| }
    assert_equal 1, @client.instance_variable_get(:@callbacks)[:visual].size
  end

  def test_on_voice_callback_registers
    @client.on_voice { |_text| }
    assert_equal 1, @client.instance_variable_get(:@callbacks)[:voice].size
  end

  def test_on_error_callback_registers
    @client.on_error { |_msg| }
    assert_equal 1, @client.instance_variable_get(:@callbacks)[:error].size
  end

  def test_on_interrupt_callback_registers
    @client.on_interrupt { |_text| }
    assert_equal 1, @client.instance_variable_get(:@callbacks)[:interrupt].size
  end

  def test_multiple_callbacks_can_register
    @client.on_visual {}
    @client.on_visual {}
    assert_equal 2, @client.instance_variable_get(:@callbacks)[:visual].size
  end

  # === Event Processing Tests ===

  def test_process_event_ready
    @client.send(:process_event, '{"type":"ready","data":{"camera":true}}')
    assert @client.instance_variable_get(:@ready)
  end

  def test_process_event_visual
    received_data = nil
    @client.on_visual { |data| received_data = data }

    @client.send(:process_event, '{"type":"visual","data":{"emotion":"happy","description":"Person smiling"}}')

    assert_equal 'happy', received_data[:emotion]
    assert_equal 'Person smiling', received_data[:description]
  end

  def test_process_event_visual_full
    received_data = nil
    @client.on_visual { |data| received_data = data }

    @client.send(:process_event, '{"type":"visual_full","data":{"description":"Full scene analysis"}}')

    assert_equal 'Full scene analysis', received_data[:description]
  end

  def test_process_event_voice
    received_text = nil
    @client.on_voice { |text| received_text = text }

    @client.send(:process_event, '{"type":"voice","data":{"text":"Hello Kira"}}')

    assert_equal 'Hello Kira', received_text
  end

  def test_process_event_interrupt
    received_text = nil
    @client.on_interrupt { |text| received_text = text }
    @client.instance_variable_set(:@speaking, true)

    @client.send(:process_event, '{"type":"interrupt","data":{"text":"stop"}}')

    assert_equal 'stop', received_text
    refute @client.speaking?
  end

  def test_process_event_speech_interrupted
    @client.instance_variable_set(:@speaking, true)

    @client.send(:process_event, '{"type":"speech_interrupted","data":{}}')

    refute @client.speaking?
  end

  def test_process_event_audio_state
    # Should not raise, just log
    @client.send(:process_event, '{"type":"audio_state","data":{"state":"SPEAKING"}}')
  end

  def test_process_event_error
    received_message = nil
    @client.on_error { |msg| received_message = msg }

    @client.send(:process_event, '{"type":"error","data":{"message":"Test error"}}')

    assert_equal 'Test error', received_message
  end

  def test_process_event_unknown_type
    # Should not raise
    @client.send(:process_event, '{"type":"unknown_event","data":{}}')
  end

  def test_process_event_empty_line
    # Should not raise
    @client.send(:process_event, '')
  end

  def test_process_event_invalid_json
    # Should not raise
    @client.send(:process_event, 'not valid json')
  end

  def test_process_event_triggers_all_callbacks
    call_count = 0
    @client.on_visual { call_count += 1 }
    @client.on_visual { call_count += 1 }

    @client.send(:process_event, '{"type":"visual","data":{"emotion":"happy"}}')

    assert_equal 2, call_count
  end

  # === Speaking State Tests ===

  def test_speak_sets_speaking_flag
    @client.instance_variable_set(:@stdin, StringIO.new)

    @client.speak('Hello!')

    assert @client.speaking?
  end

  def test_interrupt_clears_speaking_flag
    @client.instance_variable_set(:@stdin, StringIO.new)
    @client.instance_variable_set(:@speaking, true)

    @client.interrupt

    refute @client.speaking?
  end

  # === Command Sending Tests ===

  def test_send_command_writes_json
    stdin = StringIO.new
    @client.instance_variable_set(:@stdin, stdin)

    @client.send(:send_command, 'speak', text: 'Hello')

    stdin.rewind
    line = stdin.read
    parsed = JSON.parse(line)

    assert_equal 'speak', parsed['command']
    assert_equal 'Hello', parsed['text']
  end

  def test_send_command_noop_when_stdin_nil
    @client.instance_variable_set(:@stdin, nil)

    # Should not raise
    @client.send(:send_command, 'speak', text: 'Hello')
  end

  def test_send_command_noop_when_stdin_closed
    stdin = StringIO.new
    stdin.close
    @client.instance_variable_set(:@stdin, stdin)

    # Should not raise
    @client.send(:send_command, 'speak', text: 'Hello')
  end

  # === Python Path Finding Tests ===

  def test_find_python_returns_path
    path = @client.send(:find_python)

    # Should find some Python
    refute_nil path
    assert File.executable?(path)
  end
end

class UnifiedClientEventFormatTest < Minitest::Test
  def setup
    @client = Kira::Perception::UnifiedClient.new
  end

  # Test that we handle all expected event formats from Python

  def test_visual_event_format
    # Format from kira_perception.py _emit_event('visual', {...})
    json = {
      type: 'visual',
      data: {
        emotion: 'happy',
        description: 'Person smiling at screen',
        inference_ms: 150,
        frame_diff: 0.03,
        is_full_analysis: false
      },
      timestamp: Time.now.to_f
    }.to_json

    received = nil
    @client.on_visual { |data| received = data }

    @client.send(:process_event, json)

    assert_equal 'happy', received[:emotion]
    assert_equal 'Person smiling at screen', received[:description]
    assert_equal 150, received[:inference_ms]
    assert_equal false, received[:is_full_analysis]
  end

  def test_visual_full_event_format
    # Format from kira_perception.py for full analysis
    json = {
      type: 'visual_full',
      data: {
        description: 'A person sitting at a desk, typing on a laptop, looking focused',
        inference_ms: 800,
        is_full_analysis: true
      },
      timestamp: Time.now.to_f
    }.to_json

    received = nil
    @client.on_visual { |data| received = data }

    @client.send(:process_event, json)

    assert_includes received[:description], 'typing on a laptop'
    assert_equal true, received[:is_full_analysis]
  end

  def test_voice_event_format
    # Format from fast_whisper_service.py
    json = {
      type: 'voice',
      data: {
        text: 'Hello Kira, how are you?',
        language: 'en',
        latency_ms: 350
      },
      timestamp: Time.now.to_f
    }.to_json

    received = nil
    @client.on_voice { |text| received = text }

    @client.send(:process_event, json)

    assert_equal 'Hello Kira, how are you?', received
  end

  def test_interrupt_event_format
    json = {
      type: 'interrupt',
      data: {
        text: 'Kira stop'
      },
      timestamp: Time.now.to_f
    }.to_json

    received = nil
    @client.on_interrupt { |text| received = text }

    @client.send(:process_event, json)

    assert_equal 'Kira stop', received
  end

  def test_ready_event_format
    json = {
      type: 'ready',
      data: {
        camera: true,
        vlm_hz: 2.0,
        stt: true,
        tts: true,
        prewarm: true
      },
      timestamp: Time.now.to_f
    }.to_json

    @client.send(:process_event, json)

    assert @client.instance_variable_get(:@ready)
  end

  def test_error_event_format
    json = {
      type: 'error',
      data: {
        message: 'Failed to open camera'
      },
      timestamp: Time.now.to_f
    }.to_json

    received = nil
    @client.on_error { |msg| received = msg }

    @client.send(:process_event, json)

    assert_equal 'Failed to open camera', received
  end
end
