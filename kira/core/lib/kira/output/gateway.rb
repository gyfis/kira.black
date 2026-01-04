# frozen_string_literal: true

module Kira
  module Output
    class Gateway
      attr_reader :stats

      def initialize(profile:)
        @profile = profile
        @cadence_hz = profile.output.cadence_hz
        @cadence_ms = (1000.0 / @cadence_hz).to_i
        @last_output_time = 0
        @speak_engine = SpeakDecisionEngine.new(config: profile.output)
        @payload_builder = PayloadBuilder.new(profile: profile)
        @callbacks = []
        @stats = {
          outputs_emitted: 0,
          outputs_suppressed: 0,
          last_output_time: nil
        }
      end

      def on_output(&block)
        @callbacks << block
      end

      def process(state:, events:, session_context: {})
        timestamp_ms = state.timestamp.session_elapsed_ms

        unless should_emit_by_cadence?(timestamp_ms)
          @stats[:outputs_suppressed] += 1
          return nil
        end

        decision = @speak_engine.should_speak?(
          state: state,
          events: events,
          timestamp_ms: timestamp_ms
        )

        return nil unless decision.speak? || (events.any? && events.any?(&:high_priority?))

        payload = @payload_builder.build(
          state: state,
          events: events,
          session_context: session_context
        )

        llm_prompt = @payload_builder.build_for_llm(
          state: state,
          events: events,
          session_context: session_context
        )

        output = {
          payload: payload,
          llm_prompt: llm_prompt,
          decision: decision,
          should_speak: decision.speak?
        }

        @last_output_time = timestamp_ms
        @speak_engine.mark_spoke(timestamp_ms: timestamp_ms) if decision.speak?
        @stats[:outputs_emitted] += 1
        @stats[:last_output_time] = Time.now

        notify_callbacks(output)

        output
      end

      def force_output(state:, events:, session_context: {})
        payload = @payload_builder.build(
          state: state,
          events: events,
          session_context: session_context
        )

        llm_prompt = @payload_builder.build_for_llm(
          state: state,
          events: events,
          session_context: session_context
        )

        output = {
          payload: payload,
          llm_prompt: llm_prompt,
          decision: Decision.speak,
          should_speak: true,
          forced: true
        }

        @stats[:outputs_emitted] += 1
        @stats[:last_output_time] = Time.now

        notify_callbacks(output)

        output
      end

      private

      def should_emit_by_cadence?(timestamp_ms)
        return true if @last_output_time.zero?

        (timestamp_ms - @last_output_time) >= @cadence_ms
      end

      def notify_callbacks(output)
        @callbacks.each do |callback|
          callback.call(output)
        rescue StandardError => e
          Kira.logger.error("Output callback error: #{e.message}")
        end
      end
    end
  end
end
