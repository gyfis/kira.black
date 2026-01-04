# frozen_string_literal: true

require 'open3'
require 'json'
require 'shellwords'
require 'timeout'

module Kira
  module OpenCode
    class Bridge
      FAST_MODEL = 'anthropic/claude-haiku-4-5'  # For quick decisions
      SMART_MODEL = 'anthropic/claude-opus-4-5'  # For responses
      KIRA_AGENT = 'agent/kira-companion' # Custom Kira persona agent

      attr_reader :session_id

      def initialize(session_id)
        @session_id = session_id
        @logger = SemanticLogger['OpenCode::Bridge']
        @opencode_session_id = nil # Actual ses_xxx ID from OpenCode
      end

      def should_speak?(observation:, context:, persona: nil)
        prompt = build_meta_prompt(observation, context, persona)
        # Use Kira agent for decisions so it understands its role
        response = run(prompt, model: FAST_MODEL, agent: KIRA_AGENT)

        return { decision: :wait, reasoning: 'no response' } if response.nil?

        # Parse decision and reasoning
        lines = response.strip.split("\n")
        decision_line = lines.first&.strip&.upcase || 'WAIT'
        reasoning = lines[1..]&.join(' ')&.strip || ''

        decision = case decision_line
                   when /SPEAK/ then :speak
                   when /URGENT/ then :urgent
                   else :wait
                   end

        { decision: decision, reasoning: reasoning }
      end

      def respond(message)
        run(message, model: SMART_MODEL)
      end

      def send_observation(message, type: :visual)
        formatted = case type
                    when :visual then "[You see] #{message}"
                    when :voice then "[User said] \"#{message}\""
                    when :event then "[Event] #{message}"
                    else message
                    end

        run(formatted, model: SMART_MODEL, agent: KIRA_AGENT)
      end

      def init_persona(seed)
        prompt = "[Session starting] Your persona hint: #{seed}"
        run(prompt, model: SMART_MODEL, agent: KIRA_AGENT)
      end

      def greet
        prompt = '[Session starting] Greet the user warmly. You can see and hear them.'
        run(prompt, model: SMART_MODEL, agent: KIRA_AGENT)
      end

      def ping
        run('[System] Connection test - respond with OK', model: FAST_MODEL)
        true
      rescue StandardError => e
        @logger.error("Ping failed: #{e.message}")
        false
      end

      def session_initialized?
        !@opencode_session_id.nil?
      end

      private

      TIMEOUT_SECONDS = 45

      def run(message, model: nil, agent: nil)
        cmd = build_command(message, model: model, agent: agent)
        @logger.debug("OpenCode: #{message[0..60]}...")

        stdout_str = nil
        stderr_str = nil
        status = nil

        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
          stdin.close

          # Read with timeout
          deadline = Time.now + TIMEOUT_SECONDS
          stdout_data = []
          stderr_data = []

          while Time.now < deadline
            # Check if process finished
            if wait_thr.join(0.1)
              # Process done, read remaining output
              stdout_data << stdout.read
              stderr_data << stderr.read
              status = wait_thr.value
              break
            end

            # Read available data (non-blocking)
            begin
              stdout_data << stdout.read_nonblock(4096)
            rescue IO::WaitReadable, EOFError
              # No data available or EOF
            end

            begin
              stderr_data << stderr.read_nonblock(4096)
            rescue IO::WaitReadable, EOFError
              # No data available or EOF
            end
          end

          unless status
            @logger.error("OpenCode timed out after #{TIMEOUT_SECONDS}s")
            begin
              Process.kill('TERM', wait_thr.pid)
            rescue StandardError
              nil
            end
            wait_thr.join(2)
            begin
              Process.kill('KILL', wait_thr.pid)
            rescue StandardError
              nil
            end
            return nil
          end

          stdout_str = stdout_data.join
          stderr_str = stderr_data.join
        end

        unless status&.success?
          @logger.error("OpenCode failed: #{stderr_str&.slice(0, 200)}")
          return nil
        end

        parse_response(stdout_str)
      end

      def build_command(message, model: nil, agent: nil)
        cmd = %w[opencode run]

        cmd += if @opencode_session_id
                 # Continue specific session by ID
                 ['--session', @opencode_session_id]
               else
                 # First call - create new session with title, use JSON to capture session ID
                 ['--title', "Kira: #{@session_id}", '--format', 'json']
               end

        cmd += ['--agent', agent] if agent
        cmd += ['-m', model] if model
        cmd << message
        cmd
      end

      def parse_response(output)
        return nil if output.nil? || output.strip.empty?

        # Try to parse as JSON (newline-delimited JSON events)
        # This handles both the first call (with --format json) and subsequent calls
        text_parts = []
        has_json = false
        had_session_id = !@opencode_session_id.nil?

        output.each_line do |line|
          line = line.strip
          next if line.empty?

          begin
            event = JSON.parse(line)
            has_json = true
            # Capture session ID from first event if we don't have one
            @opencode_session_id ||= event['sessionID']
            # Collect text parts
            text_parts << event.dig('part', 'text') if event['type'] == 'text' && event.dig('part', 'text')
          rescue JSON::ParserError
            # Not JSON - could be plain text output
            text_parts << line unless has_json
          end
        end

        @logger.info("OpenCode session: #{@opencode_session_id}") if @opencode_session_id && !had_session_id

        text_parts.join("\n").strip
      end

      def build_meta_prompt(observation, context, persona)
        persona_hint = persona ? "Your persona: #{persona}\n" : ''
        <<~PROMPT
          [Meta-Decision Required]

          #{persona_hint}Current observation: #{observation}
          Time since last spoke: #{context[:seconds_since_spoke] || 'never'}s
          Session time: #{context[:session_elapsed] || 0}s

          Should you speak? Consider:
          - Is this interesting/important enough to comment on?
          - Have you been silent too long?
          - Would speaking interrupt the user's focus?

          Reply with ONE word on first line (SPEAK, WAIT, or URGENT)
          Then briefly explain why (10 words max) on second line.
        PROMPT
      end

      def build_persona_init_prompt(seed)
        <<~PROMPT
          [SYSTEM INITIALIZATION - READ CAREFULLY]

          You are Kira, a visual AI companion running on a user's computer. You have:
          - A camera: You receive descriptions of what you see (emotions, activities)
          - A microphone: You receive transcriptions of what the user says
          - A speaker: Your responses will be spoken aloud via TTS

          This is NOT a standard coding assistant session. You are embodied and present.

          Messages will be tagged:
          - [Visual] = what you're seeing (e.g., "Person looks happy, typing")
          - [Voice] = what the user said (e.g., "Hey Kira, how are you?")
          - [Meta-Decision Required] = decide if you should speak or stay silent

          Your persona for this session: #{seed}

          Acknowledge who you are briefly (1-2 sentences, in character). Keep responses concise since they'll be spoken aloud.
        PROMPT
      end
    end
  end
end
