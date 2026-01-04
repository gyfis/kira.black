# frozen_string_literal: true

require 'test_helper'

class RingBufferTest < Minitest::Test
  def setup
    @buffer = Kira::Support::RingBuffer.new(5)
  end

  def test_creates_buffer_with_given_capacity
    assert_equal 5, @buffer.capacity
    assert @buffer.empty?
  end

  def test_raises_error_for_non_positive_capacity
    assert_raises(ArgumentError) { Kira::Support::RingBuffer.new(0) }
    assert_raises(ArgumentError) { Kira::Support::RingBuffer.new(-1) }
  end

  def test_push_adds_items_to_buffer
    @buffer.push(1)
    @buffer.push(2)

    assert_equal 2, @buffer.size
    assert_equal [1, 2], @buffer.to_a
  end

  def test_push_overwrites_oldest_when_full
    (1..7).each { |i| @buffer.push(i) }

    assert_equal 5, @buffer.size
    assert_equal [3, 4, 5, 6, 7], @buffer.to_a
  end

  def test_supports_shovel_operator
    @buffer << 1 << 2 << 3
    assert_equal [1, 2, 3], @buffer.to_a
  end

  def test_access_by_positive_index
    (1..7).each { |i| @buffer.push(i) }

    assert_equal 3, @buffer[0]
    assert_equal 4, @buffer[1]
    assert_equal 7, @buffer[4]
  end

  def test_access_by_negative_index
    (1..7).each { |i| @buffer.push(i) }

    assert_equal 7, @buffer[-1]
    assert_equal 6, @buffer[-2]
    assert_equal 3, @buffer[-5]
  end

  def test_first_returns_first_element
    (1..7).each { |i| @buffer.push(i) }
    assert_equal 3, @buffer.first
  end

  def test_last_returns_last_element
    (1..7).each { |i| @buffer.push(i) }
    assert_equal 7, @buffer.last
  end

  def test_last_n_returns_last_n_elements
    (1..7).each { |i| @buffer.push(i) }
    assert_equal [5, 6, 7], @buffer.last(3)
  end

  def test_each_iterates_in_insertion_order
    (1..7).each { |i| @buffer.push(i) }

    result = []
    @buffer.each { |item| result << item }

    assert_equal [3, 4, 5, 6, 7], result
  end

  def test_is_enumerable
    (1..5).each { |i| @buffer.push(i) }
    assert_equal([2, 4, 6, 8, 10], @buffer.map { |x| x * 2 })
  end

  def test_reverse_each_iterates_in_reverse_order
    (1..7).each { |i| @buffer.push(i) }

    result = []
    @buffer.reverse_each { |item| result << item }

    assert_equal [7, 6, 5, 4, 3], result
  end

  def test_full_returns_false_when_not_full
    @buffer.push(1)
    refute @buffer.full?
  end

  def test_full_returns_true_when_full
    5.times { |i| @buffer.push(i) }
    assert @buffer.full?
  end

  def test_clear_empties_the_buffer
    (1..5).each { |i| @buffer.push(i) }
    @buffer.clear

    assert @buffer.empty?
    assert_equal 0, @buffer.size
  end
end
