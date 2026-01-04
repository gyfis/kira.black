# frozen_string_literal: true

require 'async'
require 'io/endpoint'
require 'io/endpoint/unix_endpoint'
require 'msgpack'
require 'dry-struct'
require 'dry-types'
require 'semantic_logger'
require 'yaml'
require 'json'
require 'set'

module Kira
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ConnectionError < Error; end
  class PerceptionError < Error; end

  class << self
    attr_accessor :logger

    def root
      @root ||= File.expand_path('..', __dir__)
    end

    def config_path
      File.join(root, 'config')
    end
  end

  # Initialize logger only once
  unless defined?(@@logger_initialized)
    SemanticLogger.default_level = :info
    SemanticLogger.add_appender(io: $stdout, formatter: :color)
    self.logger = SemanticLogger['Kira']
    @@logger_initialized = true
  end
end

# Require all files explicitly in the right order
require_relative 'kira/version'
require_relative 'kira/types'

# Support modules
require_relative 'kira/support/ring_buffer'
require_relative 'kira/support/hysteresis'
require_relative 'kira/support/metrics'

# Signal processing (new architecture)
require_relative 'kira/signal'
require_relative 'kira/signal_queue'
require_relative 'kira/sense_manager'

# Perception (legacy - kept for backwards compatibility)
require_relative 'kira/perception/frame'
require_relative 'kira/perception/client'
require_relative 'kira/perception/unified_client'
require_relative 'kira/perception/signal_source'

# State
require_relative 'kira/state/world_state'
require_relative 'kira/state/track'
require_relative 'kira/state/entity_tracker'
require_relative 'kira/state/history'
require_relative 'kira/state/distiller'

# Events
require_relative 'kira/events/event'
require_relative 'kira/events/triggers'
require_relative 'kira/events/registry'
require_relative 'kira/events/engine'

# Profiles
require_relative 'kira/profiles/profile'
require_relative 'kira/profiles/loader'

# Output
require_relative 'kira/output/speak_decision'
require_relative 'kira/output/payload_builder'
require_relative 'kira/output/gateway'

# Chat (legacy - kept for Message struct)
require_relative 'kira/chat/session'

# OpenCode integration (new)
require_relative 'kira/opencode/bridge'
require_relative 'kira/opencode/session_manager'

# Orchestrator (new)
require_relative 'kira/orchestrator'

# Runtime (legacy)
require_relative 'kira/runtime'
