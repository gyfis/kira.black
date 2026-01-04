# frozen_string_literal: true

require 'test_helper'

class LoaderTest < Minitest::Test
  def setup
    @loader = Kira::Profiles::Loader.new
  end

  def test_loads_base_profile
    profile = @loader.load('base')

    assert_equal 'base', profile.profile_id
    assert_includes profile.events.enabled_categories, 'entity_lifecycle'
  end

  def test_loads_therapy_profile_with_inheritance
    profile = @loader.load('therapy')

    assert_equal 'therapy', profile.profile_id
    assert_equal 'base', profile.extends
    assert_equal 'therapy', profile.meta.domain

    assert_includes profile.output.llm.persona[:role], 'therapeutic'
  end

  def test_loads_fitness_profile
    profile = @loader.load('fitness')

    assert_equal 'fitness', profile.profile_id
    assert_equal 'fitness', profile.meta.domain
    assert_equal 3.0, profile.output.cadence_hz
  end

  def test_raises_error_for_unknown_profile
    assert_raises(Kira::ConfigurationError) do
      @loader.load('nonexistent')
    end
  end

  def test_available_profiles_lists_profiles
    profiles = @loader.available_profiles

    assert_includes profiles, 'base'
    assert_includes profiles, 'therapy'
    assert_includes profiles, 'fitness'
  end

  def test_profile_inheritance_merges_parent_config_with_child_overrides
    therapy = @loader.load('therapy')
    base = @loader.load('base')

    assert_equal 1.0, therapy.output.cadence_hz
    assert_equal 2.0, base.output.cadence_hz

    assert therapy.perception.model_enabled?(:object_detection)
  end

  def test_profile_inheritance_combines_arrays
    therapy = @loader.load('therapy')

    assert_includes therapy.events.enabled_categories, 'engagement'
  end

  def test_profile_generates_system_prompt
    profile = @loader.load('therapy')
    prompt = profile.system_prompt

    assert_includes prompt, 'therapeutic'
    assert_includes prompt, 'empathetic'
  end
end
