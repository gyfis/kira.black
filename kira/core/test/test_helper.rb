# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'minitest/reporters'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

# Suppress logging during tests
require 'semantic_logger'
SemanticLogger.default_level = :fatal

require_relative '../lib/kira'
