# frozen_string_literal: true

require 'test_helper'

class SessionTest < Minitest::Test
  def setup
    @profile = Kira::Profiles::Loader.load('base')
    @session = Kira::Chat::Session.new(profile: @profile)
  end

  def test_initializes_with_empty_messages
    assert_equal 0, @session.messages.size
    assert @session.id.start_with?('session_')
  end

  def test_add_system_message
    @session.add_system_message('You are an assistant')

    assert_equal 1, @session.messages.size
    assert @session.messages.first.system?
    assert_equal 'You are an assistant', @session.messages.first.content
  end

  def test_add_user_message
    @session.add_user_message('Hello')

    assert_equal 1, @session.messages.size
    assert @session.messages.first.user?
    assert_equal 1, @session.stats[:messages_sent]
  end

  def test_add_assistant_message
    @session.add_assistant_message('Hi there!')

    assert_equal 1, @session.messages.size
    assert @session.messages.first.assistant?
    assert_equal 1, @session.stats[:messages_received]
  end

  def test_add_observation
    @session.add_observation('Person appeared')

    assert_equal 1, @session.messages.size
    assert_includes @session.messages.first.content, '[Visual Observation]'
    assert_includes @session.messages.first.content, 'Person appeared'
  end

  def test_context_messages_includes_system_and_recent
    @session.add_system_message('System prompt')
    25.times { |i| @session.add_user_message("Message #{i}") }

    context = @session.context_messages

    system_msgs = context.select(&:system?)
    non_system_msgs = context.reject(&:system?)

    assert_equal 1, system_msgs.size
    assert_equal Kira::Chat::Session::MAX_CONTEXT_MESSAGES, non_system_msgs.size
  end

  def test_recent_exchanges
    @session.add_user_message('Hello')
    @session.add_assistant_message('Hi there')
    @session.add_user_message('How are you?')
    @session.add_assistant_message("I'm great!")

    recent = @session.recent_exchanges(count: 2)

    assert_includes recent, 'User:'
    assert_includes recent, 'Kira:'
  end

  def test_session_elapsed_ms
    sleep(0.01)

    elapsed = @session.session_elapsed_ms

    assert_operator elapsed, :>=, 10
  end

  def test_clear_history_keeps_system_messages
    @session.add_system_message('System prompt')
    @session.add_user_message('Hello')
    @session.add_assistant_message('Hi')

    @session.clear_history(keep_system: true)

    assert_equal 1, @session.messages.size
    assert @session.messages.first.system?
  end

  def test_clear_history_removes_all
    @session.add_system_message('System prompt')
    @session.add_user_message('Hello')

    @session.clear_history(keep_system: false)

    assert_equal 0, @session.messages.size
  end

  def test_to_api_messages
    @session.add_system_message('You are an assistant')
    @session.add_user_message('Hello')
    @session.add_assistant_message('Hi there')

    api_messages = @session.to_api_messages

    assert_equal 3, api_messages.size
    assert_equal({ role: :system, content: 'You are an assistant' }, api_messages[0])
    assert_equal({ role: :user, content: 'Hello' }, api_messages[1])
    assert_equal({ role: :assistant, content: 'Hi there' }, api_messages[2])
  end
end
