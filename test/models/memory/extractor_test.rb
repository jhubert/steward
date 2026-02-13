require 'test_helper'

class Memory::ExtractorTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @extractor = Memory::Extractor.new(agent: agents(:steward))
  end

  # parse_response tests

  test 'parse_response returns items from valid JSON' do
    json = '[{"category": "fact", "content": "User lives in Toronto"}]'
    result = @extractor.parse_response(json)

    assert_equal 1, result.size
    assert_equal 'fact', result.first[:category]
    assert_equal 'User lives in Toronto', result.first[:content]
  end

  test 'parse_response returns empty array for empty JSON array' do
    result = @extractor.parse_response('[]')
    assert_equal [], result
  end

  test 'parse_response strips markdown fences' do
    json = "```json\n[{\"category\": \"preference\", \"content\": \"Prefers dark mode\"}]\n```"
    result = @extractor.parse_response(json)

    assert_equal 1, result.size
    assert_equal 'preference', result.first[:category]
  end

  test 'parse_response strips plain markdown fences' do
    json = "```\n[{\"category\": \"decision\", \"content\": \"Chose Rails over Django\"}]\n```"
    result = @extractor.parse_response(json)

    assert_equal 1, result.size
    assert_equal 'decision', result.first[:category]
  end

  test 'parse_response rejects invalid categories' do
    json = '[{"category": "opinion", "content": "Thinks Ruby is great"}]'
    result = @extractor.parse_response(json)

    assert_equal [], result
  end

  test 'parse_response skips items with blank content' do
    json = '[{"category": "fact", "content": ""}, {"category": "fact", "content": "Real fact"}]'
    result = @extractor.parse_response(json)

    assert_equal 1, result.size
    assert_equal 'Real fact', result.first[:content]
  end

  test 'parse_response returns empty array for malformed JSON' do
    result = @extractor.parse_response('this is not json at all')
    assert_equal [], result
  end

  test 'parse_response returns empty array when response is not an array' do
    result = @extractor.parse_response('{"category": "fact", "content": "oops"}')
    assert_equal [], result
  end

  test 'parse_response handles multiple valid items' do
    json = <<~JSON
      [
        {"category": "fact", "content": "Lives in Toronto"},
        {"category": "preference", "content": "Prefers morning meetings"},
        {"category": "commitment", "content": "Will send the report by Friday"}
      ]
    JSON
    result = @extractor.parse_response(json)

    assert_equal 3, result.size
    assert_equal %w[fact preference commitment], result.map { |i| i[:category] }
  end

  # build_prompt tests

  test 'build_prompt formats messages as transcript' do
    msgs = [
      Message.new(role: 'user', content: 'I live in Toronto'),
      Message.new(role: 'assistant', content: 'That is great!')
    ]
    prompt = @extractor.build_prompt(msgs, [])

    assert_includes prompt, '## Conversation Segment'
    assert_includes prompt, 'USER: I live in Toronto'
    assert_includes prompt, 'ASSISTANT: That is great!'
  end

  test 'build_prompt includes context when provided' do
    context_item = MemoryItem.new(category: 'fact', content: 'Works at Acme Corp')
    msgs = [
      Message.new(role: 'user', content: 'I got promoted'),
      Message.new(role: 'assistant', content: 'Congratulations!')
    ]
    prompt = @extractor.build_prompt(msgs, [context_item])

    assert_includes prompt, '## Already Known Facts'
    assert_includes prompt, '[fact] Works at Acme Corp'
  end

  test 'build_prompt omits known facts section when context is empty' do
    msgs = [Message.new(role: 'user', content: 'Hello')]
    prompt = @extractor.build_prompt(msgs, [])

    assert_not_includes prompt, '## Already Known Facts'
  end

  test 'build_prompt handles multiple messages' do
    msgs = [
      Message.new(role: 'user', content: 'Hello'),
      Message.new(role: 'assistant', content: 'Hi there!'),
      Message.new(role: 'user', content: 'I work at Acme'),
      Message.new(role: 'assistant', content: 'Nice!')
    ]
    prompt = @extractor.build_prompt(msgs, [])

    assert_includes prompt, "USER: Hello\nASSISTANT: Hi there!\nUSER: I work at Acme\nASSISTANT: Nice!"
  end
end
