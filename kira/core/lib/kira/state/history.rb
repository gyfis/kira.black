# frozen_string_literal: true

module Kira
  module State
    class History
      DEFAULT_CAPACITY_SECONDS = 30
      SAMPLE_RATE_HZ = 5

      attr_reader :capacity

      def initialize(capacity_seconds: DEFAULT_CAPACITY_SECONDS)
        @capacity = capacity_seconds * SAMPLE_RATE_HZ
        @buffer = Support::RingBuffer.new(@capacity)
      end

      def push(state)
        @buffer.push(state)
      end

      def current_state
        @buffer.last
      end

      def previous_state
        return nil if @buffer.size < 2

        @buffer[-2]
      end

      def window(seconds:)
        samples = [seconds * SAMPLE_RATE_HZ, @buffer.size].min
        @buffer.last(samples)
      end

      def signal_window(signal_path, seconds:)
        window(seconds: seconds).map do |state|
          extract_signal(signal_path, state)
        end.compact
      end

      def find_condition_start(signal_path, condition)
        @buffer.reverse_each do |state|
          value = extract_signal(signal_path, state)
          return nil if value.nil?

          return state.timestamp.session_elapsed_ms unless evaluate_condition(condition, value)
        end

        @buffer.first&.timestamp&.session_elapsed_ms
      end

      def entity_history(entity_id, seconds:)
        window(seconds: seconds).filter_map do |state|
          state.entity(entity_id)
        end
      end

      def size
        @buffer.size
      end

      def empty?
        @buffer.empty?
      end

      def duration_ms
        return 0 if @buffer.size < 2

        first_state = @buffer.first
        last_state = @buffer.last

        last_state.timestamp.session_elapsed_ms - first_state.timestamp.session_elapsed_ms
      end

      def clear
        @buffer.clear
      end

      private

      def extract_signal(path, state)
        path.to_s.split('.').reduce(state) do |obj, key|
          return nil if obj.nil?

          case obj
          when Hash
            obj[key.to_sym] || obj[key]
          when Array
            key =~ /^\d+$/ ? obj[key.to_i] : nil
          when Dry::Struct
            obj.respond_to?(key) ? obj.send(key) : nil
          else
            obj.respond_to?(key) ? obj.send(key) : nil
          end
        end
      end

      def evaluate_condition(condition, value)
        case condition
        when /^< (.+)$/
          value < ::Regexp.last_match(1).to_f
        when /^> (.+)$/
          value > ::Regexp.last_match(1).to_f
        when /^<= (.+)$/
          value <= ::Regexp.last_match(1).to_f
        when /^>= (.+)$/
          value >= ::Regexp.last_match(1).to_f
        when /^== (.+)$/
          value.to_s == ::Regexp.last_match(1)
        else
          false
        end
      end
    end
  end
end
