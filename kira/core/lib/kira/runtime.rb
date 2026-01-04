# frozen_string_literal: true

module Kira
  class Runtime
    attr_reader :profile, :metrics, :stats

    def initialize(profile:, socket_path: '/tmp/kira.sock', output_mode: :log, api_key: nil)
      @profile = profile
      @socket_path = socket_path
      @output_mode = output_mode
      @api_key = api_key
      @running = false
      @frame_count = 0

      @perception = Perception::Client.new(socket_path: socket_path)
      @tracker = State::EntityTracker.new
      @distiller = State::Distiller.new
      @history = State::History.new
      @event_engine = Events::Engine.new
      @gateway = Output::Gateway.new(profile: profile)
      @chat_manager = Chat::Manager.new(profile: profile, api_key: api_key)
      @metrics = Support::Metrics.new

      @previous_state = nil

      @stats = {
        frames_processed: 0,
        states_distilled: 0,
        events_fired: 0,
        chat_responses: 0,
        start_time: nil,
        last_state_time: nil
      }

      setup_event_engine
      setup_callbacks
    end

    def run
      @running = true
      @stats[:start_time] = Time.now

      log_startup

      @perception.on_frame { |frame| process_frame(frame) }
      @perception.run
    end

    def stop
      @running = false
      @perception.stop

      log_shutdown
    end

    private

    def setup_event_engine
      @event_engine.configure_from_profile(
        enabled_categories: @profile.events.enabled_categories,
        custom_events: @profile.events.custom_events,
        severity_overrides: @profile.events.severity_overrides
      )
    end

    def setup_callbacks
      @gateway.on_output do |output|
        handle_output(output)
      end

      @chat_manager.on_response do |response|
        handle_chat_response(response)
      end

      @chat_manager.on_stream_chunk do |chunk|
        handle_stream_chunk(chunk)
      end
    end

    def process_frame(frame)
      @frame_count += 1
      @stats[:frames_processed] += 1
      @metrics.increment(:frames_processed)

      entities = @tracker.update(
        detections: frame.detections,
        timestamp_ms: frame.timestamp_ms,
        poses: frame.poses
      )

      return unless @distiller.should_distill?(frame.frame_id)

      state = @distiller.distill(
        frame: frame,
        entities: entities,
        history: @history
      )

      @history.push(state)
      @stats[:states_distilled] += 1
      @stats[:last_state_time] = Time.now

      handle_state(state)
    end

    def handle_state(state)
      events = @event_engine.evaluate(state, @previous_state, @history)

      if events.any?
        @stats[:events_fired] += events.size
        events.each { |e| log_event(e) }
      end

      @gateway.process(
        state: state,
        events: events,
        session_context: @chat_manager.recent_context
      )

      @previous_state = state
      @metrics.gauge(:active_entities, state.entities.size)

      log_state(state) if @output_mode == :verbose
    end

    def handle_output(output)
      case @output_mode
      when :json
        puts JSON.generate(output[:payload])
      when :log, :verbose
        if output[:should_speak]
          @chat_manager.process_observation(
            output[:llm_prompt],
            state: @previous_state,
            events: []
          )
        end
      end
    end

    def handle_chat_response(response)
      @stats[:chat_responses] += 1

      case @output_mode
      when :json
        puts JSON.generate({ type: 'chat_response', content: response })
      when :log, :verbose
        Kira.logger.info("Kira: #{response}")
      end
    end

    def handle_stream_chunk(chunk)
      return unless @output_mode == :stream

      print chunk
      $stdout.flush
    end

    def log_startup
      Kira.logger.info('=' * 60)
      Kira.logger.info('Kira Runtime Starting')
      Kira.logger.info('=' * 60)
      Kira.logger.info("Profile: #{@profile.profile_id}")
      Kira.logger.info("Socket: #{@socket_path}")
      Kira.logger.info("Output mode: #{@output_mode}")
      Kira.logger.info("Events enabled: #{@profile.events.enabled_categories.join(', ')}")
      Kira.logger.info('')
    end

    def log_shutdown
      duration = Time.now - @stats[:start_time] if @stats[:start_time]

      Kira.logger.info('')
      Kira.logger.info('=' * 60)
      Kira.logger.info('Kira Runtime Stopped')
      Kira.logger.info('=' * 60)
      Kira.logger.info("Duration: #{format_duration(duration)}") if duration
      Kira.logger.info("Frames processed: #{@stats[:frames_processed]}")
      Kira.logger.info("States distilled: #{@stats[:states_distilled]}")
      Kira.logger.info("Events fired: #{@stats[:events_fired]}")
      Kira.logger.info("Chat responses: #{@stats[:chat_responses]}")
    end

    def log_state(state)
      entity_summary = state.entities.map do |e|
        "#{e.id}(#{e.motion.motion_class[0]})"
      end.join(', ')

      Kira.logger.debug(
        'State',
        elapsed_ms: state.timestamp.session_elapsed_ms,
        entities: state.entities.size,
        details: entity_summary
      )
    end

    def log_event(event)
      Kira.logger.info(
        "Event: #{event.type}",
        severity: event.severity,
        entities: event.entities_involved
      )
    end

    def format_duration(seconds)
      return '0s' unless seconds

      minutes = (seconds / 60).to_i
      secs = (seconds % 60).to_i

      if minutes > 0
        "#{minutes}m #{secs}s"
      else
        "#{secs}s"
      end
    end
  end
end
