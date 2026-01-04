# frozen_string_literal: true

require_relative 'test_helper'

class OrchestratorTest < Minitest::Test
  def setup
    @orchestrator = Kira::Orchestrator.new(
      session_id: 'test-session',
      persona: 'Test persona'
    )
  end

  def teardown
    @orchestrator.stop if @orchestrator.running
  end

  # === Initialization Tests ===

  def test_orchestrator_initializes
    assert_instance_of Kira::Orchestrator, @orchestrator
    assert_equal 'test-session', @orchestrator.session_id
    refute @orchestrator.running
  end

  def test_orchestrator_initializes_with_persona
    orch = Kira::Orchestrator.new(
      session_id: 'test',
      persona: 'Friendly therapist'
    )
    assert_equal 'Friendly therapist', orch.persona
  end

  def test_orchestrator_has_default_persona
    orch = Kira::Orchestrator.new(session_id: 'test')
    assert_match(/helpful/i, orch.persona)
  end

  # === Signal Source Tests ===

  def test_add_signal_source
    source = MockSignalSource.new
    @orchestrator.add_signal_source(source)

    sources = @orchestrator.instance_variable_get(:@signal_sources)
    assert_includes sources, source
  end

  def test_set_tts
    tts = MockTTS.new
    @orchestrator.set_tts(tts)

    assert_equal tts, @orchestrator.instance_variable_get(:@tts)
  end

  # === Callback Registration Tests ===

  def test_on_speak_callback_registers
    @orchestrator.on_speak { |_text| }
    assert_equal 1, @orchestrator.instance_variable_get(:@callbacks)[:on_speak].size
  end

  def test_on_signal_callback_registers
    @orchestrator.on_signal { |_signal| }
    assert_equal 1, @orchestrator.instance_variable_get(:@callbacks)[:on_signal].size
  end

  def test_on_error_callback_registers
    @orchestrator.on_error { |_msg| }
    assert_equal 1, @orchestrator.instance_variable_get(:@callbacks)[:on_error].size
  end

  def test_on_decision_callback_registers
    @orchestrator.on_decision { |_info| }
    assert_equal 1, @orchestrator.instance_variable_get(:@callbacks)[:on_decision].size
  end

  def test_multiple_callbacks_can_register
    @orchestrator.on_speak {}
    @orchestrator.on_speak {}
    assert_equal 2, @orchestrator.instance_variable_get(:@callbacks)[:on_speak].size
  end

  # === Signal Receiving Tests ===

  def test_receive_signal_adds_to_queue
    @orchestrator.instance_variable_set(:@running, true)
    signal_queue = @orchestrator.instance_variable_get(:@signal_queue)

    signal = Kira::Signal.new(type: :voice, content: 'Hello')
    @orchestrator.receive_signal(signal)

    queued = signal_queue.pop(timeout: 0)
    assert_equal signal, queued
  end

  def test_receive_signal_triggers_callback
    @orchestrator.instance_variable_set(:@running, true)
    received = nil
    @orchestrator.on_signal { |s| received = s }

    signal = Kira::Signal.new(type: :voice, content: 'Hello')
    @orchestrator.receive_signal(signal)

    assert_equal signal, received
  end

  def test_receive_signal_noop_when_not_running
    signal_queue = @orchestrator.instance_variable_get(:@signal_queue)
    signal = Kira::Signal.new(type: :voice, content: 'Hello')

    @orchestrator.receive_signal(signal)

    assert signal_queue.empty?
  end

  # === Response Cleaning Tests ===

  def test_clean_response_filters_nil
    result = @orchestrator.send(:clean_response, nil)
    assert_nil result
  end

  def test_clean_response_filters_empty
    assert_nil @orchestrator.send(:clean_response, '')
    assert_nil @orchestrator.send(:clean_response, '   ')
  end

  def test_clean_response_filters_wait
    assert_nil @orchestrator.send(:clean_response, 'WAIT')
    assert_nil @orchestrator.send(:clean_response, 'wait')
    assert_nil @orchestrator.send(:clean_response, '  WAIT  ')
  end

  def test_clean_response_filters_silence_markers
    assert_nil @orchestrator.send(:clean_response, '[SILENCE]')
    assert_nil @orchestrator.send(:clean_response, '[THOUGHTFUL SILENCE]')
    assert_nil @orchestrator.send(:clean_response, 'text [SILENCE] more')
  end

  def test_clean_response_filters_meta_reasoning
    assert_nil @orchestrator.send(:clean_response, 'Let them finish their task')
    assert_nil @orchestrator.send(:clean_response, "They're working on something")
    assert_nil @orchestrator.send(:clean_response, 'Just greeted them')
  end

  def test_clean_response_strips_wait_from_response
    result = @orchestrator.send(:clean_response, "Hello there!\n\nWAIT\n\nMore text")
    assert_equal 'Hello there!', result
  end

  def test_clean_response_returns_first_paragraph
    result = @orchestrator.send(:clean_response, "First paragraph.\n\nSecond paragraph.")
    assert_equal 'First paragraph.', result
  end

  def test_clean_response_passes_normal_text
    result = @orchestrator.send(:clean_response, 'Hello, how are you?')
    assert_equal 'Hello, how are you?', result
  end

  # === Context Building Tests ===

  def test_build_context_with_all_values
    @orchestrator.instance_variable_set(:@session_start, Time.now - 60)
    @orchestrator.instance_variable_set(:@last_spoke_at, Time.now - 10)

    context = @orchestrator.send(:build_context)

    assert_in_delta 10, context[:seconds_since_spoke], 1
    assert_in_delta 60, context[:session_elapsed], 1
  end

  def test_build_context_with_no_speech
    @orchestrator.instance_variable_set(:@session_start, Time.now - 30)

    context = @orchestrator.send(:build_context)

    assert_nil context[:seconds_since_spoke]
    assert_in_delta 30, context[:session_elapsed], 1
  end

  # === Helper Classes ===

  class MockSignalSource
    attr_reader :started, :stopped

    def initialize
      @started = false
      @stopped = false
    end

    def start(callback)
      @started = true
      @callback = callback
      true
    end

    def stop
      @stopped = true
    end

    def emit(signal)
      @callback&.call(signal)
    end
  end

  class MockTTS
    attr_reader :spoken_texts, :interrupted

    def initialize
      @spoken_texts = []
      @interrupted = false
    end

    def speak(text)
      @spoken_texts << text
    end

    def interrupt
      @interrupted = true
    end
  end
end

class SignalTest < Minitest::Test
  def test_signal_creation
    signal = Kira::Signal.new(type: :voice, content: 'Hello')

    assert_equal :voice, signal.type
    assert_equal 'Hello', signal.content
    assert_equal 100, signal.priority # voice is highest
    refute_nil signal.timestamp
  end

  def test_signal_types_have_correct_priorities
    voice = Kira::Signal.new(type: :voice, content: 'test')
    interrupt = Kira::Signal.new(type: :interrupt, content: 'test')
    screen = Kira::Signal.new(type: :screen, content: 'test')
    visual = Kira::Signal.new(type: :visual, content: 'test')
    system = Kira::Signal.new(type: :system, content: 'test')

    assert voice.priority > interrupt.priority
    assert interrupt.priority > screen.priority
    assert screen.priority > visual.priority
    assert visual.priority > system.priority
  end

  def test_voice_signal_requires_response
    signal = Kira::Signal.new(type: :voice, content: 'Hello')
    assert signal.requires_response?
  end

  def test_visual_signal_does_not_require_response
    signal = Kira::Signal.new(type: :visual, content: 'User smiling')
    refute signal.requires_response?
  end

  def test_signal_to_hash
    signal = Kira::Signal.new(
      type: :voice,
      content: 'Hello',
      metadata: { confidence: 0.95 }
    )
    hash = signal.to_h

    assert_equal :voice, hash[:type]
    assert_equal 'Hello', hash[:content]
    assert_equal({ confidence: 0.95 }, hash[:metadata])
    assert_equal 100, hash[:priority]
  end
end

class SignalQueueTest < Minitest::Test
  def setup
    @queue = Kira::SignalQueue.new
  end

  def teardown
    @queue.close
  end

  def test_push_and_pop
    signal = Kira::Signal.new(type: :voice, content: 'Hello')
    @queue.push(signal)

    popped = @queue.pop(timeout: 0)
    assert_equal signal, popped
  end

  def test_priority_ordering
    visual = Kira::Signal.new(type: :visual, content: 'visual')
    voice = Kira::Signal.new(type: :voice, content: 'voice')
    screen = Kira::Signal.new(type: :screen, content: 'screen')

    # Push in reverse priority order
    @queue << visual
    @queue << screen
    @queue << voice

    # Should pop in priority order
    assert_equal :voice, @queue.pop(timeout: 0).type
    assert_equal :screen, @queue.pop(timeout: 0).type
    assert_equal :visual, @queue.pop(timeout: 0).type
  end

  def test_empty_queue_returns_nil_on_timeout
    result = @queue.pop(timeout: 0.01)
    assert_nil result
  end

  def test_size
    assert_equal 0, @queue.size

    @queue << Kira::Signal.new(type: :voice, content: 'a')
    @queue << Kira::Signal.new(type: :voice, content: 'b')

    assert_equal 2, @queue.size
  end

  def test_clear
    @queue << Kira::Signal.new(type: :voice, content: 'a')
    @queue << Kira::Signal.new(type: :voice, content: 'b')

    @queue.clear
    assert @queue.empty?
  end

  def test_close
    @queue.close
    assert @queue.closed?

    # Push after close should be ignored
    @queue << Kira::Signal.new(type: :voice, content: 'ignored')
    assert @queue.empty?
  end

  def test_pop_returns_nil_when_closed
    @queue.close
    assert_nil @queue.pop(timeout: 0)
  end

  def test_thread_safety
    results = []
    mutex = Mutex.new

    # Producer thread
    producer = Thread.new do
      10.times do |i|
        @queue << Kira::Signal.new(type: :voice, content: "msg-#{i}")
        sleep 0.001
      end
    end

    # Consumer thread
    consumer = Thread.new do
      10.times do
        signal = @queue.pop(timeout: 1)
        mutex.synchronize { results << signal.content } if signal
      end
    end

    producer.join
    consumer.join

    assert_equal 10, results.size
  end
end

class OrchestratorLifecycleTest < Minitest::Test
  def test_start_sets_running_flag
    orchestrator = create_orchestrator_with_mock_bridge

    orchestrator.start

    assert orchestrator.running
  ensure
    orchestrator.stop
  end

  def test_stop_sets_running_false
    orchestrator = create_orchestrator_with_mock_bridge
    orchestrator.start

    orchestrator.stop

    refute orchestrator.running
  end

  def test_stop_is_idempotent
    orchestrator = create_orchestrator_with_mock_bridge

    # Should not raise
    orchestrator.stop
    orchestrator.stop
  end

  def test_start_starts_signal_sources
    orchestrator = create_orchestrator_with_mock_bridge
    source = OrchestratorTest::MockSignalSource.new
    orchestrator.add_signal_source(source)

    orchestrator.start
    sleep 0.1

    assert source.started
  ensure
    orchestrator.stop
  end

  def test_stop_stops_signal_sources
    orchestrator = create_orchestrator_with_mock_bridge
    source = OrchestratorTest::MockSignalSource.new
    orchestrator.add_signal_source(source)

    orchestrator.start
    orchestrator.stop

    assert source.stopped
  end

  private

  def create_orchestrator_with_mock_bridge
    orchestrator = Kira::Orchestrator.new(
      session_id: 'lifecycle-test',
      persona: 'Test'
    )

    bridge = orchestrator.instance_variable_get(:@bridge)
    bridge.define_singleton_method(:init_persona) { |_| }
    bridge.define_singleton_method(:greet) { nil }

    orchestrator
  end
end
