# frozen_string_literal: true

module Kira
  module Profiles
    class PerceptionConfig < Dry::Struct
      attribute :models, Types::Hash.default({}.freeze)
      attribute :compute_budget, Types::Hash.optional

      def model_enabled?(name)
        models.dig(name.to_sym, :enabled) != false
      end

      def model_priority(name)
        models.dig(name.to_sym, :priority) || 'normal'
      end
    end

    class StateConfig < Dry::Struct
      attribute :entity_focus, Types::Array.of(Types::String).default(['person'].freeze)
      attribute :max_entities, Types::Integer.default(5)
      attribute :confidence_thresholds, Types::Hash.default({}.freeze)
      attribute :extensions, Types::Hash.default({}.freeze)
    end

    class EventsConfig < Dry::Struct
      attribute :enabled_categories, Types::Array.of(Types::String).default([].freeze)
      attribute :disabled_categories, Types::Array.of(Types::String).default([].freeze)
      attribute :custom_events, Types::Array.of(Types::Hash).default([].freeze)
      attribute :severity_overrides, Types::Hash.default({}.freeze)
    end

    class LLMConfig < Dry::Struct
      attribute :persona, Types::Hash.default({}.freeze)
      attribute :instructions, Types::String.optional
      attribute :response_constraints, Types::Hash.default({}.freeze)
    end

    class InteractionRules < Dry::Struct
      attribute :speak_when, Types::Array.of(Types::Hash).default([].freeze)
      attribute :do_not_speak_when, Types::Array.of(Types::Hash).default([].freeze)
    end

    class OutputConfig < Dry::Struct
      attribute :cadence_hz, Types::Float.default(2.0)
      attribute(:llm, LLMConfig.default { LLMConfig.new })
      attribute(:interaction_rules, InteractionRules.default { InteractionRules.new })
    end

    class ProfileMeta < Dry::Struct
      attribute :name, Types::String.optional
      attribute :domain, Types::String.optional
      attribute :description, Types::String.optional
    end

    class Profile < Dry::Struct
      attribute :profile_id, Types::String
      attribute :version, Types::String.default('1.0.0')
      attribute :extends, Types::String.optional
      attribute(:meta, ProfileMeta.default { ProfileMeta.new })
      attribute(:perception, PerceptionConfig.default { PerceptionConfig.new })
      attribute(:state, StateConfig.default { StateConfig.new })
      attribute(:events, EventsConfig.default { EventsConfig.new })
      attribute(:output, OutputConfig.default { OutputConfig.new })

      def system_prompt
        llm = output.llm
        persona = llm.persona

        parts = []

        parts << "You are a #{persona[:role]}." if persona[:role]

        parts << "Tone: #{persona[:tone]}" if persona[:tone]

        parts << "Expertise: #{persona[:expertise]}" if persona[:expertise]

        if llm.instructions
          parts << ''
          parts << llm.instructions
        end

        constraints = llm.response_constraints
        if constraints.any?
          parts << ''
          parts << 'Response constraints:'
          parts << "- Max length: #{constraints[:max_length]}" if constraints[:max_length]
          parts << "- Avoid: #{constraints[:avoid].join(', ')}" if constraints[:avoid]
          parts << "- Prefer: #{constraints[:prefer].join(', ')}" if constraints[:prefer]
        end

        parts.join("\n")
      end
    end
  end
end
