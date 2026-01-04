# frozen_string_literal: true

module Kira
  module Profiles
    class Loader
      class << self
        def load(profile_id_or_path)
          new.load(profile_id_or_path)
        end

        def profiles_dir
          File.join(Kira.config_path, 'profiles')
        end
      end

      def load(profile_id_or_path)
        data = load_raw(profile_id_or_path)
        data = resolve_inheritance(data)
        build_profile(data)
      end

      def available_profiles
        Dir.glob(File.join(self.class.profiles_dir, '*.yml')).map do |path|
          File.basename(path, '.yml')
        end
      end

      private

      def load_raw(profile_id_or_path)
        path = if File.exist?(profile_id_or_path)
                 profile_id_or_path
               else
                 profile_path(profile_id_or_path)
               end

        raise ConfigurationError, "Profile not found: #{profile_id_or_path}" unless File.exist?(path)

        YAML.safe_load(File.read(path), symbolize_names: true, permitted_classes: [Symbol])
      end

      def profile_path(profile_id)
        File.join(self.class.profiles_dir, "#{profile_id}.yml")
      end

      def resolve_inheritance(data)
        return data unless data[:extends]

        parent_data = load_raw(data[:extends])
        parent_data = resolve_inheritance(parent_data)

        deep_merge(parent_data, data)
      end

      def deep_merge(base, overlay)
        result = base.dup

        overlay.each do |key, value|
          result[key] = if value.is_a?(Hash) && result[key].is_a?(Hash)
                          deep_merge(result[key], value)
                        elsif value.is_a?(Array) && result[key].is_a?(Array)
                          (result[key] + value).uniq
                        else
                          value
                        end
        end

        result
      end

      def build_profile(data)
        Profile.new(
          profile_id: data[:profile_id],
          version: data[:version] || '1.0.0',
          extends: data[:extends],
          meta: build_meta(data[:meta] || {}),
          perception: build_perception(data[:perception] || {}),
          state: build_state(data[:state] || {}),
          events: build_events(data[:events] || {}),
          output: build_output(data[:output] || {})
        )
      end

      def build_meta(data)
        ProfileMeta.new(
          name: data[:name],
          domain: data[:domain],
          description: data[:description]
        )
      end

      def build_perception(data)
        PerceptionConfig.new(
          models: data[:models] || {},
          compute_budget: data[:compute_budget]
        )
      end

      def build_state(data)
        StateConfig.new(
          entity_focus: data[:entity_focus] || ['person'],
          max_entities: data[:max_entities] || 5,
          confidence_thresholds: data[:confidence_thresholds] || {},
          extensions: data[:extensions] || {}
        )
      end

      def build_events(data)
        EventsConfig.new(
          enabled_categories: data[:enabled_categories] || [],
          disabled_categories: data[:disabled_categories] || [],
          custom_events: data[:custom_events] || [],
          severity_overrides: data[:severity_overrides] || {}
        )
      end

      def build_output(data)
        OutputConfig.new(
          cadence_hz: data[:cadence_hz] || 2.0,
          llm: build_llm(data[:llm] || {}),
          interaction_rules: build_interaction_rules(data[:interaction_rules] || {})
        )
      end

      def build_llm(data)
        LLMConfig.new(
          persona: data[:persona] || {},
          instructions: data[:instructions],
          response_constraints: data[:response_constraints] || {}
        )
      end

      def build_interaction_rules(data)
        InteractionRules.new(
          speak_when: data[:speak_when] || [],
          do_not_speak_when: data[:do_not_speak_when] || []
        )
      end
    end
  end
end
