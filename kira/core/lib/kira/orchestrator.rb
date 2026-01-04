# frozen_string_literal: true

module Kira
  # The Orchestrator is Kira's brain. It:
  # - Receives signals from various sources (camera, microphone, screen, etc.)
  # - Maintains a single OpenCode session for conversation continuity
  # - Decides when and how to respond based on signals and context
  # - Outputs speech via TTS
  #
  # Signal sources are pluggable and stateless - they just emit signals.
  # The orchestrator maintains all state (conversation, timing, etc.)
  class Orchestrator
    attr_reader :session_id, :running, :persona

    def initialize(session_id:, persona: nil)
      @session_id = session_id
      @persona = persona || 'Helpful, friendly AI companion'
      @logger = SemanticLogger['Orchestrator']

      # Core components
      @bridge = OpenCode::Bridge.new(session_id)
      @signal_queue = SignalQueue.new
      @running = false

      # State tracking
      @last_spoke_at = nil
      @session_start = nil

      # Callbacks for UI
      @callbacks = {
        on_speak: [],
        on_signal: [],
        on_decision: [],
        on_error: []
      }

      # Signal sources (pluggable)
      @signal_sources = []

      # TTS output (optional)
      @tts = nil
    end

    # Register a signal source. Source must respond to:
    # - start(signal_callback) -> bool
    # - stop
    def add_signal_source(source)
      @signal_sources << source
    end

    # Set TTS output. Must respond to:
    # - speak(text)
    # - interrupt
    def set_tts(tts)
      @tts = tts
    end

    def start
      @running = true
      @session_start = Time.now
      @logger.info("Starting Kira session: #{@session_id}")

      # Start all signal sources
      @signal_sources.each do |source|
        source.start(->(signal) { receive_signal(signal) })
      end

      # Start processing thread
      @processor_thread = Thread.new { process_loop }

      # Initialize conversation
      initialize_session
    end

    def stop
      @running = false
      @signal_queue.close

      # Stop all signal sources
      @signal_sources.each(&:stop)

      @processor_thread&.join(3)
      @logger.info('Kira stopped')
    end

    # Receive a signal from any source
    def receive_signal(signal)
      return unless @running

      @signal_queue << signal
      @callbacks[:on_signal].each { |cb| cb.call(signal) }
    end

    # Callbacks
    def on_speak(&block)
      @callbacks[:on_speak] << block
    end

    def on_signal(&block)
      @callbacks[:on_signal] << block
    end

    def on_decision(&block)
      @callbacks[:on_decision] << block
    end

    def on_error(&block)
      @callbacks[:on_error] << block
    end

    private

    def initialize_session
      @logger.info("Initializing with persona: #{@persona[0..50]}...")

      @bridge.init_persona(@persona)

      greeting = @bridge.greet
      speak(greeting) if greeting
    end

    def process_loop
      while @running
        signal = @signal_queue.pop(timeout: 0.1)
        next unless signal

        begin
          process_signal(signal)
        rescue StandardError => e
          @logger.error("Signal processing error: #{e.message}")
          @callbacks[:on_error].each { |cb| cb.call(e.message) }
        end
      end
    end

    def process_signal(signal)
      case signal.type
      when :voice
        process_voice(signal)
      when :visual, :screen
        process_observation(signal)
      when :interrupt
        handle_interrupt(signal)
      else
        @logger.debug("Unknown signal type: #{signal.type}")
      end
    end

    def process_voice(signal)
      @logger.info("Voice: #{signal.content[0..50]}...")

      # Voice always gets a response
      emit_decision(signal, :speak, 'User spoke')

      response = @bridge.send_observation(signal.content, type: :voice)
      speak(response) if response
    end

    def process_observation(signal)
      context = build_context
      result = @bridge.should_speak?(
        observation: signal.content,
        context: context,
        persona: @persona
      )

      emit_decision(signal, result[:decision], result[:reasoning])

      return unless %i[speak urgent].include?(result[:decision])

      response = @bridge.send_observation(signal.content, type: signal.type)
      speak(response) if response
    end

    def handle_interrupt(signal)
      @logger.info("Interrupt: #{signal.content}")
      @tts&.interrupt
    end

    def speak(text)
      return if text.nil? || text.strip.empty?

      cleaned = clean_response(text)
      return if cleaned.nil? || cleaned.empty?

      @last_spoke_at = Time.now
      @logger.info("Speaking: #{cleaned[0..80]}...")

      @callbacks[:on_speak].each { |cb| cb.call(cleaned) }
      @tts&.speak(cleaned)
    end

    def emit_decision(signal, decision, reasoning)
      info = {
        signal_type: signal.type,
        content: signal.content[0..60],
        decision: decision,
        reasoning: reasoning,
        seconds_since_spoke: seconds_since_spoke,
        session_seconds: session_elapsed
      }
      @callbacks[:on_decision].each { |cb| cb.call(info) }
    end

    def build_context
      {
        seconds_since_spoke: seconds_since_spoke,
        session_elapsed: session_elapsed
      }
    end

    def seconds_since_spoke
      return nil unless @last_spoke_at

      (Time.now - @last_spoke_at).round
    end

    def session_elapsed
      return 0 unless @session_start

      (Time.now - @session_start).round
    end

    def clean_response(text)
      return nil if text.nil?

      text = text.strip

      # Filter non-speech responses
      return nil if text.upcase == 'WAIT'
      return nil if text.match?(/^\[.*SILENCE.*\]$/i)
      return nil if text.include?('[SILENCE]')

      # Remove leaked meta-reasoning
      text = text.split(/\n\s*WAIT\s*\n/i).first || text

      lines = text.split("\n").reject do |line|
        line.strip.match?(/^(Let them|Give them|Still |They're |Just |Been |Time to |User )/i)
      end
      text = lines.join("\n").strip

      # Take first paragraph only
      text = text.split(/\n\n+/).first&.strip || text

      text.empty? ? nil : text
    end
  end
end
