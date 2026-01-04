# frozen_string_literal: true

require 'open3'
require 'json'

module Kira
  # Manages sense processes (Python) and routes signals/commands between them and the orchestrator.
  # Each sense runs as a separate process communicating via JSON lines on stdin/stdout.
  class SenseManager
    SENSES_PATH = File.expand_path('../../../../senses', __dir__)

    attr_reader :running

    def initialize
      @logger = SemanticLogger['SenseManager']
      @running = false
      @senses = {}  # name -> SenseProcess
      @outputs = {} # name -> SenseProcess
      @signal_callback = nil
      @mutex = Mutex.new
    end

    def add_sense(name, **options)
      @mutex.synchronize do
        @senses[name.to_s] = SenseProcess.new(
          name: name.to_s,
          type: :sense,
          path: File.join(SENSES_PATH, name.to_s),
          options: options
        )
      end
    end

    def add_output(name, **options)
      @mutex.synchronize do
        @outputs[name.to_s] = SenseProcess.new(
          name: name.to_s,
          type: :output,
          path: File.join(SENSES_PATH, name.to_s),
          options: options
        )
      end
    end

    def on_signal(&block)
      @signal_callback = block
    end

    def start
      @running = true
      @logger.info('Starting sense manager')

      # Start all senses
      @senses.each do |_name, process|
        start_process(process)
      end

      # Start all outputs
      @outputs.each do |_name, process|
        start_process(process)
      end

      # Wait for all to be ready
      wait_for_ready

      # Send start command to all senses
      @senses.each_value { |p| send_command(p, 'start') }

      @logger.info('All senses started')
    end

    def stop
      return unless @running

      @running = false
      @logger.info('Stopping sense manager')

      # Stop all processes
      (@senses.values + @outputs.values).each do |process|
        send_command(process, 'stop')
        process.stop
      end

      @logger.info('Sense manager stopped')
    end

    def speak(text)
      voice = @outputs['voice']
      return unless voice&.running?

      send_command(voice, 'speak', text: text)
    end

    def interrupt
      voice = @outputs['voice']
      return unless voice&.running?

      send_command(voice, 'interrupt')
    end

    def configure_sense(name, **options)
      process = @senses[name.to_s] || @outputs[name.to_s]
      return unless process&.running?

      send_command(process, 'configure', **options)
    end

    def mute_hearing
      configure_sense('hearing', mute: true)
    end

    def unmute_hearing
      configure_sense('hearing', mute: false)
    end

    private

    def start_process(process)
      return if process.running?

      @logger.info("Starting #{process.type}: #{process.name}")

      process.start do |message|
        handle_message(process, message)
      end
    end

    def wait_for_ready(timeout: 60)
      deadline = Time.now + timeout
      all_ready = false

      until all_ready || Time.now > deadline
        all_ready = (@senses.values + @outputs.values).all?(&:ready?)
        sleep 0.1 unless all_ready
      end

      return if all_ready

      not_ready = (@senses.values + @outputs.values).reject(&:ready?).map(&:name)
      @logger.warn("Timeout waiting for senses: #{not_ready.join(', ')}")
    end

    def send_command(process, command, **options)
      return unless process.running?

      msg = { command: command, options: options }
      process.send_message(msg)
    end

    def handle_message(process, message)
      type = message[:type]&.to_sym

      case type
      when :status
        handle_status(process, message)
      when :signal
        handle_signal(process, message)
      else
        @logger.debug("Unknown message type from #{process.name}: #{type}")
      end
    end

    def handle_status(process, message)
      status = message[:status]

      case status
      when 'ready'
        process.mark_ready
        @logger.info("#{process.name} ready")
      when 'error'
        @logger.error("#{process.name} error: #{message[:message]}")
      when 'stopped'
        @logger.info("#{process.name} stopped")
      end
    end

    def handle_signal(_process, message)
      return unless @signal_callback

      signal = Signal.new(
        type: message[:sense]&.to_sym || :unknown,
        content: message[:content] || '',
        metadata: message[:metadata] || {},
        timestamp: message[:timestamp] ? Time.at(message[:timestamp]) : Time.now
      )

      # Override priority if specified
      signal.instance_variable_set(:@priority, message[:priority]) if message[:priority]

      @signal_callback.call(signal)
    end
  end

  # Represents a running sense/output process
  class SenseProcess
    attr_reader :name, :type, :path, :options

    def initialize(name:, type:, path:, options: {})
      @name = name
      @type = type
      @path = path
      @options = options
      @logger = SemanticLogger["Sense::#{name}"]
      @running = false
      @ready = false
      @stdin = nil
      @stdout = nil
      @stderr = nil
      @wait_thread = nil
      @reader_thread = nil
      @message_callback = nil
      @mutex = Mutex.new
    end

    def running?
      @mutex.synchronize { @running }
    end

    def ready?
      @mutex.synchronize { @ready }
    end

    def mark_ready
      @mutex.synchronize { @ready = true }
    end

    def start(&message_callback)
      @message_callback = message_callback

      python = find_python
      raise "Python not found for sense #{@name}" unless python

      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
        python, '-m', "senses.#{@name}",
        chdir: File.dirname(@path)
      )

      @running = true

      @reader_thread = Thread.new { read_loop }
      @stderr_thread = Thread.new { read_stderr }

      @logger.debug("Process started: #{@name}")
    end

    def stop
      @mutex.synchronize { @running = false }

      @stdin&.close
      @stdout&.close
      @stderr&.close
      @wait_thread&.kill

      @logger.debug("Process stopped: #{@name}")
    end

    def send_message(msg)
      return unless @stdin && !@stdin.closed?

      @stdin.puts(msg.to_json)
      @stdin.flush
    rescue IOError, Errno::EPIPE
      @logger.warn("Failed to send message to #{@name}")
    end

    private

    def read_loop
      while @running && (line = @stdout&.gets)
        process_line(line.strip)
      end
    rescue IOError
      # Stream closed
    end

    def read_stderr
      while @running && (line = @stderr&.gets)
        @logger.debug("[stderr] #{line.strip}")
      end
    rescue IOError
      # Stream closed
    end

    def process_line(line)
      return if line.empty?

      begin
        message = JSON.parse(line, symbolize_names: true)
        @message_callback&.call(message)
      rescue JSON::ParserError
        @logger.warn("Failed to parse: #{line[0..100]}")
      end
    end

    def find_python
      # Try senses venv first
      venv_python = File.join(File.dirname(@path), '.venv', 'bin', 'python')
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
