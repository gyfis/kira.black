# frozen_string_literal: true

require 'open3'
require 'json'
require 'fileutils'

module Kira
  module OpenCode
    class SessionManager
      SESSION_PREFIX = 'kira:'
      CONFIG_DIR = File.expand_path('~/.kira')
      CURRENT_SESSION_FILE = File.join(CONFIG_DIR, 'current_session')

      def initialize
        @logger = SemanticLogger['OpenCode::SessionManager']
        ensure_config_dir
      end

      def list_sessions
        stdout, stderr, status = Open3.capture3('opencode', 'session', 'list', '--format', 'json')

        unless status.success?
          @logger.error("Failed to list sessions: #{stderr}")
          return []
        end

        sessions = parse_session_list(stdout)
        sessions.select { |s| s[:title]&.start_with?(SESSION_PREFIX) }
      end

      def create_session(name, persona_seed: nil)
        title = "#{SESSION_PREFIX}#{name}"

        # Create session by sending initial message
        bridge = Bridge.new(title)

        if persona_seed
          @logger.info("Initializing persona for #{title}")
          response = bridge.init_persona(persona_seed)
          @logger.info("Persona initialized: #{response&.slice(0, 100)}...")
        else
          # Just ping to create the session
          bridge.run('[System] Session initialized', model: Bridge::SMART_MODEL)
        end

        save_current_session(title)

        { id: title, title: title, persona_seed: persona_seed }
      end

      def resume_session(session_id)
        sessions = list_sessions
        session = sessions.find { |s| s[:id] == session_id || s[:title] == session_id }

        unless session
          @logger.error("Session not found: #{session_id}")
          return nil
        end

        save_current_session(session[:id] || session[:title])
        session
      end

      def current_session
        return nil unless File.exist?(CURRENT_SESSION_FILE)

        session_id = File.read(CURRENT_SESSION_FILE).strip
        return nil if session_id.empty?

        session_id
      end

      def clear_current_session
        FileUtils.rm_f(CURRENT_SESSION_FILE)
      end

      def session_exists?(name_or_id)
        sessions = list_sessions
        sessions.any? do |s|
          s[:id] == name_or_id || s[:title] == name_or_id || s[:title] == "#{SESSION_PREFIX}#{name_or_id}"
        end
      end

      private

      def ensure_config_dir
        FileUtils.mkdir_p(CONFIG_DIR)
      end

      def save_current_session(session_id)
        File.write(CURRENT_SESSION_FILE, session_id)
        @logger.info("Saved current session: #{session_id}")
      end

      def parse_session_list(output)
        return [] if output.nil? || output.strip.empty?

        # opencode session list --format json returns JSON array
        begin
          sessions = JSON.parse(output, symbolize_names: true)
          return [] unless sessions.is_a?(Array)

          sessions
        rescue JSON::ParserError => e
          @logger.warn("Failed to parse session list as JSON, trying line parsing: #{e.message}")
          parse_session_list_lines(output)
        end
      end

      def parse_session_list_lines(output)
        # Fallback: parse line by line if not JSON
        output.lines.filter_map do |line|
          next if line.strip.empty?

          # Try to extract session info from line
          # Format might be: "session_id  title  last_active"
          parts = line.strip.split(/\s{2,}/)
          next if parts.empty?

          { id: parts[0], title: parts[1] || parts[0] }
        end
      end
    end
  end
end
