# frozen_string_literal: true

module Kira
  module Support
    class Metrics
      attr_reader :counters, :gauges, :histograms

      def initialize
        @counters = Hash.new(0)
        @gauges = {}
        @histograms = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      def increment(name, by: 1, labels: {})
        key = metric_key(name, labels)
        @mutex.synchronize { @counters[key] += by }
      end

      def gauge(name, value, labels: {})
        key = metric_key(name, labels)
        @mutex.synchronize { @gauges[key] = value }
      end

      def observe(name, value, labels: {})
        key = metric_key(name, labels)
        @mutex.synchronize do
          @histograms[key] << value
          @histograms[key] = @histograms[key].last(1000) # Keep last 1000 observations
        end
      end

      def get_counter(name, labels: {})
        key = metric_key(name, labels)
        @mutex.synchronize { @counters[key] }
      end

      def get_gauge(name, labels: {})
        key = metric_key(name, labels)
        @mutex.synchronize { @gauges[key] }
      end

      def get_histogram_stats(name, labels: {})
        key = metric_key(name, labels)

        @mutex.synchronize do
          values = @histograms[key]
          return nil if values.empty?

          sorted = values.sort
          count = sorted.size

          {
            count: count,
            min: sorted.first,
            max: sorted.last,
            mean: sorted.sum / count.to_f,
            p50: sorted[count / 2],
            p95: sorted[(count * 0.95).to_i],
            p99: sorted[(count * 0.99).to_i]
          }
        end
      end

      def to_h
        @mutex.synchronize do
          {
            counters: @counters.dup,
            gauges: @gauges.dup,
            histograms: @histograms.transform_values { |v| v.size }
          }
        end
      end

      def reset
        @mutex.synchronize do
          @counters.clear
          @gauges.clear
          @histograms.clear
        end
      end

      private

      def metric_key(name, labels)
        return name.to_s if labels.empty?

        label_str = labels.map { |k, v| "#{k}=#{v}" }.sort.join(',')
        "#{name}{#{label_str}}"
      end
    end
  end
end
