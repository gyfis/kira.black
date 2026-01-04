# frozen_string_literal: true

require 'test_helper'

class HysteresisTest < Minitest::Test
  def setup
    @hysteresis = Kira::Support::Hysteresis.new(
      enter_threshold: 0.7,
      exit_threshold: 0.3,
      min_dwell_ms: 100
    )
  end

  def test_starts_in_inactive_state
    refute @hysteresis.active?
  end

  def test_raises_error_if_exit_equals_enter
    assert_raises(ArgumentError) do
      Kira::Support::Hysteresis.new(enter_threshold: 0.5, exit_threshold: 0.5)
    end
  end

  def test_raises_error_if_exit_greater_than_enter
    assert_raises(ArgumentError) do
      Kira::Support::Hysteresis.new(enter_threshold: 0.5, exit_threshold: 0.7)
    end
  end

  def test_does_not_activate_below_enter_threshold
    @hysteresis.update(0.5, 0)
    refute @hysteresis.active?
  end

  def test_activates_when_crossing_enter_threshold_after_min_dwell
    @hysteresis.update(0.5, 0)
    @hysteresis.update(0.8, 150)

    assert @hysteresis.active?
  end

  def test_does_not_activate_before_min_dwell
    @hysteresis.update(0.5, 0)
    @hysteresis.update(0.8, 50)

    refute @hysteresis.active?
  end

  def test_stays_active_in_hysteresis_band
    @hysteresis.update(0.8, 0)
    @hysteresis.update(0.8, 150)
    assert @hysteresis.active?

    @hysteresis.update(0.5, 300)
    assert @hysteresis.active?
  end

  def test_deactivates_below_exit_threshold_after_min_dwell
    @hysteresis.update(0.8, 0)
    @hysteresis.update(0.8, 150)
    assert @hysteresis.active?

    @hysteresis.update(0.2, 300)
    refute @hysteresis.active?
  end

  def test_requires_min_dwell_for_deactivation_too
    @hysteresis.update(0.8, 0)
    @hysteresis.update(0.8, 150)
    @hysteresis.update(0.2, 200)

    assert @hysteresis.active?

    @hysteresis.update(0.2, 350)
    refute @hysteresis.active?
  end

  def test_reset_returns_to_inactive_state
    @hysteresis.update(0.8, 0)
    @hysteresis.update(0.8, 150)
    assert @hysteresis.active?

    @hysteresis.reset
    refute @hysteresis.active?
  end
end
