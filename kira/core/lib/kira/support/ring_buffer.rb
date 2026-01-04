# frozen_string_literal: true

module Kira
  module Support
    class RingBuffer
      include Enumerable

      attr_reader :capacity

      def initialize(capacity)
        raise ArgumentError, 'Capacity must be positive' unless capacity.positive?

        @capacity = capacity
        @buffer = []
        @start = 0
      end

      def push(item)
        if @buffer.size < @capacity
          @buffer.push(item)
        else
          @buffer[@start] = item
          @start = (@start + 1) % @capacity
        end
        self
      end
      alias << push

      def [](index)
        return nil if @buffer.empty?

        actual_index = if index.negative?
                         (@start + @buffer.size + index) % @buffer.size
                       else
                         (@start + index) % @buffer.size
                       end

        @buffer[actual_index]
      end

      def first
        return nil if @buffer.empty?

        @buffer[@start]
      end

      def last(n = nil)
        return self[-1] if n.nil?
        return [] if @buffer.empty?

        n = [n, @buffer.size].min
        result = []
        n.times do |i|
          result << self[-(n - i)]
        end
        result
      end

      def each
        return enum_for(:each) unless block_given?

        @buffer.size.times do |i|
          yield self[i]
        end
      end

      def reverse_each
        return enum_for(:reverse_each) unless block_given?

        (@buffer.size - 1).downto(0) do |i|
          yield self[i]
        end
      end

      def size
        @buffer.size
      end

      def empty?
        @buffer.empty?
      end

      def full?
        @buffer.size == @capacity
      end

      def clear
        @buffer = []
        @start = 0
        self
      end

      def to_a
        map(&:itself)
      end
    end
  end
end
