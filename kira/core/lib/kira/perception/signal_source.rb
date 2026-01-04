# frozen_string_literal: true

require_relative 'unified_client'
require_relative '../signal'

module Kira
  module Perception
    # Adapts the UnifiedClient (Python perception service) to the SignalSource interface.
    # Converts perception events (visual, voice, interrupt) into Signal objects.
    class SignalSource
      def initialize
        @logger = SemanticLogger['Perception::SignalSource']
        @client = UnifiedClient.new
        @signal_callback = nil
      end

      # Start the perception service and begin emitting signals.
      # @param signal_callback [Proc] Called with each Signal object
      # @return [Boolean] true if started successfully
      def start(signal_callback)
        @signal_callback = signal_callback

        # Wire up client callbacks to emit signals
        @client.on_visual do |data|
          emit_visual_signal(data)
        end

        @client.on_voice do |text|
          emit_voice_signal(text)
        end

        @client.on_interrupt do |text|
          emit_interrupt_signal(text)
        end

        @client.on_error do |message|
          @logger.error("Perception error: #{message}")
        end

        @client.start
      end

      def stop
        @client.stop
      end

      # Expose TTS capability for orchestrator
      def speak(text)
        @client.speak(text)
      end

      def interrupt
        @client.interrupt
      end

      def speaking?
        @client.speaking?
      end

      private

      def emit_visual_signal(data)
        return unless @signal_callback

        # data contains: emotion, description, inference_ms, is_full_analysis
        emotion = data[:emotion] || data['emotion']
        description = data[:description] || data['description']
        is_full = data[:is_full_analysis] || data['is_full_analysis']

        content = if is_full && description
                    "[Visual] #{description} (emotion: #{emotion})"
                  else
                    "[Visual] User appears #{emotion}"
                  end

        signal = Signal.new(
          type: :visual,
          content: content,
          metadata: {
            emotion: emotion,
            description: description,
            inference_ms: data[:inference_ms] || data['inference_ms'],
            is_full_analysis: is_full
          }
        )

        @signal_callback.call(signal)
      end

      def emit_voice_signal(text)
        return unless @signal_callback
        return if text.nil? || text.strip.empty?

        signal = Signal.new(
          type: :voice,
          content: text.strip,
          metadata: {}
        )

        @signal_callback.call(signal)
      end

      def emit_interrupt_signal(text)
        return unless @signal_callback

        signal = Signal.new(
          type: :interrupt,
          content: text || 'User interrupted',
          metadata: {}
        )

        @signal_callback.call(signal)
      end
    end
  end
end
