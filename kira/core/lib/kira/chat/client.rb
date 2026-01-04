# frozen_string_literal: true

module Kira
  module Chat
    class Client
      DEFAULT_MODEL = 'claude-sonnet-4-20250514'
      MAX_TOKENS = 256

      attr_reader :model, :stats

      def initialize(model: nil, api_key: nil)
        @model = model || DEFAULT_MODEL
        @api_key = api_key || ENV['ANTHROPIC_API_KEY']
        @stats = {
          requests: 0,
          errors: 0,
          total_tokens: 0
        }

        configure_client
      end

      def chat(session)
        @stats[:requests] += 1

        messages = session.to_api_messages

        begin
          response = send_request(messages)

          content = extract_content(response)
          session.add_assistant_message(content)

          @stats[:total_tokens] += response[:usage][:total_tokens] if response[:usage]

          content
        rescue StandardError => e
          @stats[:errors] += 1
          Kira.logger.error("Chat error: #{e.message}")
          raise ChatError, e.message
        end
      end

      def stream_chat(session, &block)
        @stats[:requests] += 1

        messages = session.to_api_messages

        begin
          full_response = ''

          stream_request(messages) do |chunk|
            full_response += chunk
            block.call(chunk) if block_given?
          end

          session.add_assistant_message(full_response)
          full_response
        rescue StandardError => e
          @stats[:errors] += 1
          Kira.logger.error("Stream chat error: #{e.message}")
          raise ChatError, e.message
        end
      end

      private

      def configure_client
        return if @api_key.nil? || @api_key.empty?

        begin
          require 'ruby_llm'
          RubyLLM.configure do |config|
            config.anthropic_api_key = @api_key
          end
          @configured = true
        rescue LoadError
          Kira.logger.warn('ruby_llm not available, using mock client')
          @configured = false
        end
      end

      def send_request(messages)
        return mock_response(messages) unless @configured

        chat = RubyLLM.chat(model: @model)

        messages.each do |msg|
          case msg[:role].to_s
          when 'system'
            chat.with_instructions(msg[:content])
          when 'user'
            chat.ask(msg[:content])
          when 'assistant'
            # Skip assistant messages for context
          end
        end

        response = chat.ask(messages.last[:content])

        {
          content: response.content,
          usage: { total_tokens: 100 }
        }
      end

      def stream_request(messages, &block)
        unless @configured
          mock_stream(messages, &block)
          return
        end

        chat = RubyLLM.chat(model: @model)

        system_msg = messages.find { |m| m[:role].to_s == 'system' }
        chat.with_instructions(system_msg[:content]) if system_msg

        user_messages = messages.select { |m| m[:role].to_s == 'user' }
        last_message = user_messages.last

        chat.ask(last_message[:content]) do |chunk|
          block.call(chunk.content) if chunk.content
        end
      end

      def mock_response(messages)
        last_user = messages.reverse.find { |m| m[:role].to_s == 'user' }

        content = if last_user && last_user[:content].include?('Visual Observation')
                    generate_mock_observation_response(last_user[:content])
                  else
                    "I'm observing the scene. Let me know if you'd like me to comment on anything specific."
                  end

        {
          content: content,
          usage: { total_tokens: 50 }
        }
      end

      def mock_stream(messages, &block)
        response = mock_response(messages)

        response[:content].chars.each_slice(5) do |chars|
          block.call(chars.join)
          sleep(0.02)
        end
      end

      def generate_mock_observation_response(observation)
        if observation.include?('appeared')
          'I notice someone has come into view. Hello!'
        elsif observation.include?('stillness')
          "I notice you've been quite still. Take your time - I'm here when you're ready."
        elsif observation.include?('active') || observation.include?('moving')
          'I see some activity happening. Keep up the good work!'
        else
          "I'm watching and here to help when needed."
        end
      end

      def extract_content(response)
        if response.is_a?(Hash)
          response[:content] || response['content']
        else
          response.to_s
        end
      end
    end

    class ChatError < Kira::Error; end
  end
end
