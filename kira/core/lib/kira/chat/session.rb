# frozen_string_literal: true

module Kira
  module Chat
    class Message
      attr_reader :role, :content, :timestamp, :metadata

      def initialize(role:, content:, timestamp: Time.now, metadata: {})
        @role = role
        @content = content
        @timestamp = timestamp
        @metadata = metadata
      end

      def to_h
        {
          role: @role,
          content: @content
        }
      end

      def user?
        @role == :user || @role == 'user'
      end

      def assistant?
        @role == :assistant || @role == 'assistant'
      end

      def system?
        @role == :system || @role == 'system'
      end
    end

    class Session
      attr_reader :id, :messages, :profile, :started_at, :stats

      MAX_CONTEXT_MESSAGES = 20
      MAX_CONTEXT_TOKENS = 4000

      def initialize(profile:)
        @id = "session_#{SecureRandom.hex(8)}"
        @profile = profile
        @messages = []
        @started_at = Time.now
        @client = nil
        @stats = {
          messages_sent: 0,
          messages_received: 0,
          total_tokens: 0,
          errors: 0
        }
      end

      def add_system_message(content)
        @messages << Message.new(role: :system, content: content)
      end

      def add_user_message(content, metadata: {})
        @messages << Message.new(role: :user, content: content, metadata: metadata)
        @stats[:messages_sent] += 1
      end

      def add_assistant_message(content, metadata: {})
        @messages << Message.new(role: :assistant, content: content, metadata: metadata)
        @stats[:messages_received] += 1
      end

      def add_observation(observation_text)
        add_user_message("[Visual Observation]\n#{observation_text}", metadata: { type: :observation })
      end

      def context_messages
        system_msgs = @messages.select(&:system?)
        conversation_msgs = @messages.reject(&:system?).last(MAX_CONTEXT_MESSAGES)

        system_msgs + conversation_msgs
      end

      def recent_exchanges(count: 3)
        conversation = @messages.reject(&:system?)
        recent = conversation.last(count * 2)

        recent.map do |msg|
          prefix = msg.assistant? ? 'Kira' : 'User'
          "#{prefix}: #{msg.content.lines.first&.strip || ''}"
        end.join(' | ')
      end

      def session_elapsed_ms
        ((Time.now - @started_at) * 1000).to_i
      end

      def to_api_messages
        context_messages.map(&:to_h)
      end

      def clear_history(keep_system: true)
        @messages = if keep_system
                      @messages.select(&:system?)
                    else
                      []
                    end
      end
    end
  end
end
