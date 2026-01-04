# frozen_string_literal: true

module Kira
  module Chat
    class Manager
      attr_reader :session, :client, :profile

      def initialize(profile:, api_key: nil)
        @profile = profile
        @client = Client.new(api_key: api_key)
        @session = Session.new(profile: profile)
        @pending_responses = []
        @callbacks = {
          on_response: [],
          on_stream_chunk: [],
          on_error: []
        }

        setup_session
      end

      def on_response(&block)
        @callbacks[:on_response] << block
      end

      def on_stream_chunk(&block)
        @callbacks[:on_stream_chunk] << block
      end

      def on_error(&block)
        @callbacks[:on_error] << block
      end

      def process_observation(observation_text, state:, events:)
        @session.add_observation(observation_text)

        return unless should_respond?(state, events)

        generate_response
      end

      def user_message(content)
        @session.add_user_message(content)
        generate_response
      end

      def generate_response(stream: false)
        if stream
          generate_streaming_response
        else
          generate_blocking_response
        end
      rescue ChatError => e
        notify_callbacks(:on_error, e)
        nil
      end

      def recent_context
        {
          recent_exchanges: @session.recent_exchanges(count: 3),
          session_elapsed_ms: @session.session_elapsed_ms,
          message_count: @session.messages.size
        }
      end

      def reset_session
        @session = Session.new(profile: @profile)
        setup_session
      end

      private

      def setup_session
        system_prompt = @profile.system_prompt
        @session.add_system_message(system_prompt) unless system_prompt.empty?

        intro = build_session_intro
        @session.add_system_message(intro)
      end

      def build_session_intro
        domain = @profile.meta.domain || 'general'
        name = @profile.meta.name || 'Session'

        <<~INTRO
          You are starting a new #{name} session.
          Domain: #{domain}

          You will receive visual observations about the user. Respond naturally and helpfully.
          Keep responses concise unless a longer response is needed.

          You can see the user through their camera. Comment on what you observe when appropriate.
        INTRO
      end

      def should_respond?(_state, events)
        return true if events.any?(&:high_priority?)

        return true if events.any? { |e| e.type == 'entity_appeared' }

        true
      end

      def generate_blocking_response
        response = @client.chat(@session)
        notify_callbacks(:on_response, response)
        response
      end

      def generate_streaming_response
        full_response = ''

        @client.stream_chat(@session) do |chunk|
          full_response += chunk
          notify_callbacks(:on_stream_chunk, chunk)
        end

        notify_callbacks(:on_response, full_response)
        full_response
      end

      def notify_callbacks(type, data)
        @callbacks[type].each do |callback|
          callback.call(data)
        rescue StandardError => e
          Kira.logger.error("Chat callback error (#{type}): #{e.message}")
        end
      end
    end
  end
end
