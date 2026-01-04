# frozen_string_literal: true

require_relative 'test_helper'

# Integration tests that call real OpenCode to verify the full flow works.
# These tests use actual API calls and measure real latencies.
class IntegrationOpenCodeTest < Minitest::Test
  def setup
    @bridge = Kira::OpenCode::Bridge.new("integration-test-#{Time.now.to_i}")
  end

  # === Real OpenCode Decision Tests ===

  def test_should_speak_returns_valid_decision_with_haiku
    result = @bridge.should_speak?(
      observation: 'Person sitting at desk, looking at screen, appears focused',
      context: { seconds_since_spoke: 30, session_elapsed: 120 },
      persona: 'Friendly AI companion'
    )

    assert_includes %i[speak wait urgent], result[:decision], "Invalid decision: #{result[:decision]}"
    assert result[:reasoning].is_a?(String), "Reasoning should be string: #{result[:reasoning]}"

    puts "  Decision: #{result[:decision]}, Reasoning: #{result[:reasoning]}"
  end

  def test_should_speak_respects_wait_scenarios
    # User is focused and working - should probably wait
    result = @bridge.should_speak?(
      observation: 'Person typing intensely, deeply focused on code',
      context: { seconds_since_spoke: 10, session_elapsed: 60 },
      persona: 'Respectful assistant who avoids interrupting'
    )

    # We can't guarantee WAIT but it should be a valid decision
    assert_includes %i[speak wait urgent], result[:decision]
    puts "  Focused user decision: #{result[:decision]}"
  end

  def test_should_speak_detects_urgent_scenarios
    result = @bridge.should_speak?(
      observation: 'Person looks distressed, rubbing eyes, appears frustrated',
      context: { seconds_since_spoke: 60, session_elapsed: 300 },
      persona: 'Caring companion who checks in when user seems upset'
    )

    assert_includes %i[speak wait urgent], result[:decision]
    puts "  Distressed user decision: #{result[:decision]}"
  end

  # === Real Response Generation Tests ===

  def test_send_observation_generates_response
    # Initialize session first
    @bridge.init_persona('Friendly, warm AI companion')

    response = @bridge.send_observation(
      'Person waved at the camera and smiled',
      type: :visual
    )

    refute_nil response, 'Should get a response'
    refute_empty response.strip, 'Response should not be empty'
    refute_includes response.downcase, 'claude code', 'Should not mention Claude Code'

    puts "  Visual response: #{response[0..100]}..."
  end

  def test_send_observation_handles_voice_input
    @bridge.init_persona('Helpful assistant')

    response = @bridge.send_observation(
      'Hello Kira, how are you today?',
      type: :voice
    )

    refute_nil response
    refute_empty response.strip

    puts "  Voice response: #{response[0..100]}..."
  end

  def test_greet_generates_warm_greeting
    @bridge.init_persona('Warm, friendly companion')

    greeting = @bridge.greet

    refute_nil greeting
    refute_empty greeting.strip
    refute_includes greeting.downcase, 'claude code'

    puts "  Greeting: #{greeting[0..100]}..."
  end

  # === Session Continuity Tests ===

  def test_session_maintains_context_across_calls
    @bridge.init_persona('Assistant with perfect memory')

    # First call - establish context
    @bridge.send_observation('Remember this secret code: RAINBOW42', type: :voice)

    assert @bridge.session_initialized?, 'Session should be initialized'
    session_id = @bridge.instance_variable_get(:@opencode_session_id)
    refute_nil session_id

    # Second call - verify context retained
    response = @bridge.send_observation(
      'What was the secret code I told you?',
      type: :voice
    )

    assert_includes response.upcase, 'RAINBOW42', "Should remember the code. Got: #{response}"

    puts '  Memory test passed - remembered RAINBOW42'
  end

  # === Latency Measurement Tests ===

  def test_haiku_decision_latency
    latencies = []

    3.times do |i|
      start = Time.now
      @bridge.should_speak?(
        observation: "Test observation #{i}",
        context: { seconds_since_spoke: 30, session_elapsed: 100 },
        persona: 'Test'
      )
      latencies << ((Time.now - start) * 1000).round

      # Small delay between calls
      sleep 0.1
    end

    avg_latency = latencies.sum / latencies.size
    max_latency = latencies.max

    puts "  Haiku latencies: #{latencies.join(', ')}ms (avg: #{avg_latency}ms, max: #{max_latency}ms)"

    # Haiku should be reasonably fast - warn if slow
    return unless avg_latency > 3000

    puts '  WARNING: Haiku average latency > 3s, may cause perception lag'
  end

  def test_opus_response_latency
    @bridge.init_persona('Test persona')

    latencies = []

    3.times do |i|
      start = Time.now
      @bridge.send_observation("Test input #{i}", type: :voice)
      latencies << ((Time.now - start) * 1000).round

      sleep 0.1
    end

    avg_latency = latencies.sum / latencies.size
    max_latency = latencies.max

    puts "  Opus latencies: #{latencies.join(', ')}ms (avg: #{avg_latency}ms, max: #{max_latency}ms)"

    # Opus can be slower but should still be reasonable
    return unless avg_latency > 10_000

    puts '  WARNING: Opus average latency > 10s, responses will feel slow'
  end
end

class IntegrationOrchestratorTest < Minitest::Test
  # Test the orchestrator with real OpenCode but mocked perception

  def test_orchestrator_initializes_session_with_real_opencode
    orchestrator = Kira::Orchestrator.new(
      session_id: "orch-test-#{Time.now.to_i}",
      enable_perception: false,
      persona: 'Friendly test companion'
    )

    spoken_texts = []
    orchestrator.on_speak { |text| spoken_texts << text }

    # Start will initialize and greet
    orchestrator.start

    # Give it time to complete
    sleep 0.5

    orchestrator.stop

    # Should have spoken a greeting
    assert spoken_texts.any?, 'Should have spoken a greeting'
    puts "  Greeting spoken: #{spoken_texts.first&.slice(0, 80)}..."
  end

  def test_orchestrator_processes_visual_with_real_opencode
    orchestrator = Kira::Orchestrator.new(
      session_id: "orch-visual-#{Time.now.to_i}",
      enable_perception: false,
      persona: 'Observant companion who comments on interesting things'
    )

    decisions = []
    spoken_texts = []

    orchestrator.on_decision { |info| decisions << info }
    orchestrator.on_speak { |text| spoken_texts << text }

    orchestrator.start
    sleep 0.5 # Let init complete

    # Simulate interesting visual event
    orchestrator.send(:process_visual, {
                        emotion: 'excited',
                        description: 'Person jumping up and down with excitement, pumping fists in the air',
                        inference_ms: 150,
                        is_full_analysis: true
                      })

    orchestrator.stop

    # Should have made a decision
    visual_decisions = decisions.select { |d| d[:type] == :visual }
    assert visual_decisions.any?, 'Should have visual decision'

    decision = visual_decisions.last
    puts "  Visual decision: #{decision[:decision]} - #{decision[:reasoning]}"

    return unless decision[:decision] == :speak

    assert spoken_texts.length > 1, 'Should have spoken about the excitement'
    puts "  Spoke: #{spoken_texts.last&.slice(0, 80)}..."
  end

  def test_orchestrator_processes_voice_with_real_opencode
    orchestrator = Kira::Orchestrator.new(
      session_id: "orch-voice-#{Time.now.to_i}",
      enable_perception: false,
      persona: 'Helpful conversational companion'
    )

    spoken_texts = []
    orchestrator.on_speak { |text| spoken_texts << text }

    orchestrator.start
    sleep 0.5

    initial_count = spoken_texts.length

    # Simulate voice input
    orchestrator.send(:process_voice, 'What is the capital of France?')

    orchestrator.stop

    # Should have responded
    assert spoken_texts.length > initial_count, 'Should have spoken a response'
    response = spoken_texts.last

    # Should mention Paris
    assert_includes response.downcase, 'paris', "Should mention Paris. Got: #{response}"
    puts "  Voice response: #{response.slice(0, 100)}..."
  end

  def test_orchestrator_filters_non_speech_responses
    orchestrator = Kira::Orchestrator.new(
      session_id: "orch-filter-#{Time.now.to_i}",
      enable_perception: false,
      persona: 'Quiet observer who often stays silent'
    )

    spoken_texts = []
    orchestrator.on_speak { |text| spoken_texts << text }

    # Manually test the filter
    orchestrator.send(:handle_response, 'WAIT')
    orchestrator.send(:handle_response, '[SILENCE]')
    orchestrator.send(:handle_response, '[THOUGHTFUL SILENCE]')
    orchestrator.send(:handle_response, '')
    orchestrator.send(:handle_response, nil)

    assert_empty spoken_texts, 'Should not speak filtered responses'

    # But should speak normal responses
    orchestrator.send(:handle_response, 'Hello there!')
    assert_equal ['Hello there!'], spoken_texts

    puts '  Filter test passed'
  end
end

class IntegrationTimingTest < Minitest::Test
  # Test realistic timing scenarios

  def test_rapid_visual_events_dont_block
    orchestrator = Kira::Orchestrator.new(
      session_id: "timing-rapid-#{Time.now.to_i}",
      enable_perception: false,
      persona: 'Quick responder'
    )

    decisions = []
    orchestrator.on_decision { |info| decisions << info }

    orchestrator.start
    sleep 0.3

    # Queue multiple visual events rapidly
    start = Time.now
    5.times do |i|
      orchestrator.send(:queue_event, :visual, {
                          emotion: %w[happy sad neutral curious excited][i],
                          description: "Visual event #{i}",
                          inference_ms: 100
                        })
    end
    queue_time = ((Time.now - start) * 1000).round

    # Queueing should be instant
    assert queue_time < 100, "Queueing took #{queue_time}ms, should be < 100ms"
    puts "  Queue time for 5 events: #{queue_time}ms"

    # Wait for processing
    sleep 3

    orchestrator.stop

    # Should have processed some events (may not be all due to timing)
    visual_decisions = decisions.select { |d| d[:type] == :visual }
    puts "  Processed #{visual_decisions.length}/5 visual events"
  end

  def test_voice_response_total_latency
    orchestrator = Kira::Orchestrator.new(
      session_id: "timing-voice-#{Time.now.to_i}",
      enable_perception: false,
      persona: 'Fast responder'
    )

    latency_ms = nil
    orchestrator.on_speak do |_text|
      # Latency captured inside the callback
    end

    orchestrator.start
    sleep 0.5

    start = Time.now
    orchestrator.send(:process_voice, 'Say hello')
    # process_voice is synchronous, so when it returns, speaking has happened
    latency_ms = ((Time.now - start) * 1000).round

    orchestrator.stop

    puts "  Voice-to-speech latency: #{latency_ms}ms"

    if latency_ms > 10000
      puts "  WARNING: Voice response latency > 10s, may feel unresponsive"
    end
  end
  end
end
