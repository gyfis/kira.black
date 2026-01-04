# frozen_string_literal: true

require 'open3'
require 'json'

module Kira
  module Perception
    class UnifiedClient
      PYTHON_SERVICE = File.expand_path('../../../../perception/kira_perception.py', __dir__)

      attr_reader :running

      def initialize
        @logger = SemanticLogger['Perception::UnifiedClient']
        @running = false
        @callbacks = { visual: [], voice: [], error: [], interrupt: [] }
        @process = nil
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @speaking = false
      end

      def on_visual(&block)
        @callbacks[:visual] << block
      end

      def on_voice(&block)
        @callbacks[:voice] << block
      end

      def on_error(&block)
        @callbacks[:error] << block
      end

      def on_interrupt(&block)
        @callbacks[:interrupt] << block
      end

      def speaking?
        @speaking
      end

      def start
        @logger.info('Starting perception service...')

        python_path = find_python
        unless python_path
          @logger.error('Python not found')
          return false
        end

        # Start the Python process
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
          python_path, PYTHON_SERVICE
        )

        @running = true

        # Start reader threads
        @stdout_thread = Thread.new { read_stdout }
        @stderr_thread = Thread.new { read_stderr }

        # Wait for ready signal (60s timeout for model warmup - first run can be slow)
        started = false
        120.times do
          sleep 0.5
          if @ready
            started = true
            break
          end
        end

        unless started
          @logger.error('Perception service failed to start')
          stop
          return false
        end

        @logger.info('Perception service started')
        true
      end

      def stop
        return unless @running

        @running = false

        begin
          send_command('stop')
        rescue StandardError
          nil
        end

        @stdin&.close
        @stdout&.close
        @stderr&.close
        @wait_thread&.kill

        @logger.info('Perception service stopped')
      end

      def speak(text)
        @speaking = true
        send_command('speak', text: text)
      end

      def interrupt
        send_command('interrupt')
        @speaking = false
      end

      private

      def send_command(command, **data)
        return unless @stdin && !@stdin.closed?

        # Ensure text is properly encoded as UTF-8
        data = data.transform_values do |v|
          v.is_a?(String) ? v.encode('UTF-8', invalid: :replace, undef: :replace) : v
        end

        msg = { command: command }.merge(data)
        @stdin.puts(msg.to_json)
        @stdin.flush
      end

      def read_stdout
        while @running && (line = @stdout&.gets)
          process_event(line.strip)
        end
      rescue IOError
        # Stream closed
      end

      def read_stderr
        while @running && (line = @stderr&.gets)
          line = line.strip
          # Show warmup progress at info level, rest at debug
          if line.include?('ready') || line.include?('loaded') || line.include?('Warming') || line.include?('warmed')
            @logger.info("[Perception] #{line}")
          else
            @logger.debug("[Perception] #{line}")
          end
        end
      rescue IOError
        # Stream closed
      end

      def process_event(line)
        return if line.empty?

        begin
          event = JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError => e
          @logger.warn("Failed to parse event: #{e.message}")
          return
        end

        type = event[:type]&.to_sym
        data = event[:data] || {}

        case type
        when :ready
          @ready = true
          @logger.info("Perception ready: #{data}")
        when :visual, :visual_full
          # Pass full data hash with emotion and description
          @callbacks[:visual].each { |cb| cb.call(data) }
        when :voice
          @callbacks[:voice].each { |cb| cb.call(data[:text]) }
        when :interrupt
          @speaking = false
          @logger.info("Speech interrupted: #{data[:text]}")
          @callbacks[:interrupt].each { |cb| cb.call(data[:text]) }
        when :speech_interrupted
          @speaking = false
          @logger.debug('Speech stopped')
        when :audio_state
          @logger.debug("Audio state: #{data[:state]}")
        when :error
          @logger.error("Perception error: #{data[:message]}")
          @callbacks[:error].each { |cb| cb.call(data[:message]) }
        else
          @logger.debug("Unknown event type: #{type}")
        end
      end

      def find_python
        # Try uv venv first (preferred)
        uv_venv_python = File.expand_path('../../../../perception/.venv/bin/python', __dir__)
        return uv_venv_python if File.executable?(uv_venv_python)

        # Try old venv location
        venv_python = File.expand_path('../../../../perception/venv/bin/python', __dir__)
        return venv_python if File.executable?(venv_python)

        # Try system python
        %w[python3 python].each do |cmd|
          path = `which #{cmd} 2>/dev/null`.strip
          return path unless path.empty?
        end

        nil
      end
    end
  end
end
