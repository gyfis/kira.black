# frozen_string_literal: true

require 'dry-types'

module Kira
  module Types
    include Dry.Types()

    # Custom types for the domain
    Timestamp = Types::Coercible::Integer.constrained(gteq: 0)
    Confidence = Types::Coercible::Float.constrained(gteq: 0.0, lteq: 1.0)
    NormalizedFloat = Types::Coercible::Float.constrained(gteq: 0.0, lteq: 1.0)
    BoundingBox = Types::Array.of(Types::Coercible::Float)
    Centroid = Types::Array.of(Types::Coercible::Float)

    # Enums with defaults - use .default first, then constrain
    TrackState = Types::String.default('tentative').enum('tentative', 'confirmed', 'lost', 'deleted')
    EntityType = Types::String.default('person').enum('person', 'hand', 'face', 'object')
    Severity = Types::String.default('info').enum('debug', 'info', 'notice', 'warning', 'alert')
    MotionClass = Types::String.default('stationary').enum('stationary', 'moving', 'fast_moving')
  end
end
