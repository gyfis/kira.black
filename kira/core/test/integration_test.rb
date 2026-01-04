# frozen_string_literal: true

require_relative 'test_helper'

# Integration tests that actually call OpenCode
# These are slower but verify real functionality
class IntegrationTest < Minitest::Test
  def test_opencode_is_available
    output = `which opencode 2>&1`
    assert $?.success?, "OpenCode not found: #{output}"
  end

  def test_opencode_can_run_simple_command
    output = `opencode run -m anthropic/claude-haiku-4-5 "Reply with only: OK" 2>&1`
    assert $?.success?, "OpenCode failed: #{output}"
    assert_includes output.downcase, 'ok'
  end

  def test_kira_agent_exists
    output = `opencode agent list 2>&1`
    assert $?.success?, "Failed to list agents: #{output}"
    assert_includes output, 'kira-companion', 'Kira agent not found. Run: opencode agent create'
  end

  def test_opencode_with_kira_agent
    skip 'Kira agent not installed' unless agent_exists?('kira-companion')

    output = `opencode run --agent agent/kira-companion -m anthropic/claude-haiku-4-5 "Say hello briefly" 2>&1`
    assert $?.success?, "OpenCode with agent failed: #{output}"
    # Kira should respond warmly, not say "I'm Claude Code"
    refute_includes output.downcase, 'claude code', 'Agent not working - got Claude Code response'
  end

  def test_session_continuity
    # Create a session
    output1 = `opencode run --title "test-continuity" --format json -m anthropic/claude-haiku-4-5 "Remember the word: BANANA" 2>&1`
    assert $?.success?, "First call failed: #{output1}"

    # Extract session ID
    session_id = nil
    output1.each_line do |line|
      data = JSON.parse(line)
      session_id = data['sessionID'] if data['sessionID']
      break if session_id
    rescue JSON::ParserError
      next
    end

    assert session_id, 'Could not extract session ID'

    # Continue session and check if it remembers
    output2 = `opencode run --session #{session_id} -m anthropic/claude-haiku-4-5 "What word did I ask you to remember?" 2>&1`
    assert $?.success?, "Second call failed: #{output2}"
    assert_includes output2.upcase, 'BANANA', 'Session did not maintain context'
  end

  private

  def agent_exists?(name)
    output = `opencode agent list 2>&1`
    output.include?(name)
  end
end
