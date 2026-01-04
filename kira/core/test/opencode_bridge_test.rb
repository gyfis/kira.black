# frozen_string_literal: true

require_relative 'test_helper'

class OpenCodeBridgeTest < Minitest::Test
  def setup
    @bridge = Kira::OpenCode::Bridge.new('test-session')
  end

  def test_bridge_initializes
    assert_instance_of Kira::OpenCode::Bridge, @bridge
    assert_equal 'test-session', @bridge.session_id
    refute @bridge.session_initialized?
  end

  def test_build_command_first_call
    # First call should create session with title and JSON format
    cmd = @bridge.send(:build_command, 'test message', model: 'anthropic/claude-haiku-4-5')

    assert_includes cmd, 'opencode'
    assert_includes cmd, 'run'
    assert_includes cmd, '--title'
    assert_includes cmd, '--format'
    assert_includes cmd, 'json'
    assert_includes cmd, '-m'
    assert_includes cmd, 'anthropic/claude-haiku-4-5'
    assert_includes cmd, 'test message'
    refute_includes cmd, '--session'
  end

  def test_build_command_with_agent
    cmd = @bridge.send(:build_command, 'test', agent: 'agent/kira-companion')

    assert_includes cmd, '--agent'
    assert_includes cmd, 'agent/kira-companion'
  end

  def test_parse_response_extracts_session_id
    json_output = <<~JSON
      {"type":"step_start","sessionID":"ses_abc123"}
      {"type":"text","sessionID":"ses_abc123","part":{"text":"Hello!"}}
      {"type":"step_finish","sessionID":"ses_abc123"}
    JSON

    result = @bridge.send(:parse_response, json_output)

    assert_equal 'Hello!', result
    assert @bridge.session_initialized?
  end

  def test_parse_response_plain_text_after_init
    # Simulate session already initialized
    @bridge.instance_variable_set(:@opencode_session_id, 'ses_abc123')

    result = @bridge.send(:parse_response, "Plain text response\n")

    assert_equal 'Plain text response', result
  end

  def test_should_speak_parses_decision
    # Mock the run method
    @bridge.define_singleton_method(:run) do |_msg, **_opts|
      "WAIT\nUser is focused, don't interrupt"
    end

    result = @bridge.should_speak?(
      observation: 'User typing',
      context: { seconds_since_spoke: 5, session_elapsed: 30 }
    )

    assert_equal :wait, result[:decision]
    assert_includes result[:reasoning], 'focused'
  end

  def test_should_speak_handles_speak_decision
    @bridge.define_singleton_method(:run) do |_msg, **_opts|
      "SPEAK\nTime to check in with user"
    end

    result = @bridge.should_speak?(
      observation: 'User looks sad',
      context: { seconds_since_spoke: 60, session_elapsed: 300 }
    )

    assert_equal :speak, result[:decision]
  end

  def test_should_speak_handles_nil_response
    @bridge.define_singleton_method(:run) { |_msg, **_opts| nil }

    result = @bridge.should_speak?(
      observation: 'test',
      context: {}
    )

    assert_equal :wait, result[:decision]
    assert_equal 'no response', result[:reasoning]
  end

  def test_should_speak_handles_urgent_decision
    @bridge.define_singleton_method(:run) do |_msg, **_opts|
      "URGENT\nUser appears distressed"
    end

    result = @bridge.should_speak?(
      observation: 'User crying',
      context: { seconds_since_spoke: 10 }
    )

    assert_equal :urgent, result[:decision]
    assert_includes result[:reasoning], 'distressed'
  end

  def test_parse_response_handles_multiline_text_parts
    json_output = <<~JSON
      {"type":"text","sessionID":"ses_123","part":{"text":"SPEAK"}}
      {"type":"text","sessionID":"ses_123","part":{"text":"User has been silent for a while"}}
    JSON

    result = @bridge.send(:parse_response, json_output)

    assert_equal "SPEAK\nUser has been silent for a while", result
  end

  def test_parse_response_handles_mixed_json_and_plain_text
    # Once we see JSON, plain text lines are ignored (they're likely noise)
    mixed_output = <<~OUTPUT
      {"type":"text","sessionID":"ses_123","part":{"text":"Hello"}}
      Some random stderr output
      {"type":"text","sessionID":"ses_123","part":{"text":"World"}}
    OUTPUT

    result = @bridge.send(:parse_response, mixed_output)

    assert_equal "Hello\nWorld", result
    refute_includes result, 'random stderr'
  end

  def test_parse_response_handles_pure_plain_text
    # Plain text without any JSON should be returned as-is
    plain_output = "WAIT\nUser is typing code"

    result = @bridge.send(:parse_response, plain_output)

    assert_equal "WAIT\nUser is typing code", result
  end

  def test_parse_response_ignores_non_text_json_events
    json_output = <<~JSON
      {"type":"step_start","sessionID":"ses_123"}
      {"type":"tool_call","sessionID":"ses_123","part":{"tool":"read"}}
      {"type":"text","sessionID":"ses_123","part":{"text":"Result"}}
      {"type":"step_finish","sessionID":"ses_123"}
    JSON

    result = @bridge.send(:parse_response, json_output)

    assert_equal 'Result', result
  end

  def test_parse_response_handles_empty_output
    assert_nil @bridge.send(:parse_response, nil)
    assert_nil @bridge.send(:parse_response, '')
    assert_nil @bridge.send(:parse_response, "   \n  ")
  end

  def test_build_command_subsequent_call_uses_session_id
    # Simulate session already initialized
    @bridge.instance_variable_set(:@opencode_session_id, 'ses_xyz789')

    cmd = @bridge.send(:build_command, 'follow-up message')

    assert_includes cmd, '--session'
    assert_includes cmd, 'ses_xyz789'
    refute_includes cmd, '--title'
    refute_includes cmd, '--format'
  end

  def test_session_id_only_logged_once
    # First parse should capture and log session ID
    json_output = '{"type":"text","sessionID":"ses_new","part":{"text":"Hi"}}'

    refute @bridge.session_initialized?
    @bridge.send(:parse_response, json_output)
    assert @bridge.session_initialized?

    # Second parse should not re-log (we can't easily test logging, but we verify state)
    @bridge.send(:parse_response, json_output)
    assert_equal 'ses_new', @bridge.instance_variable_get(:@opencode_session_id)
  end
end
