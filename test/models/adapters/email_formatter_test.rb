require 'test_helper'

class Adapters::EmailFormatterTest < ActiveSupport::TestCase
  test 'converts markdown bold to HTML' do
    html = Adapters::EmailFormatter.to_html("This is **bold** text")

    assert_includes html, "<strong>bold</strong>"
  end

  test 'converts markdown lists to HTML' do
    html = Adapters::EmailFormatter.to_html("- Item one\n- Item two\n- Item three")

    assert_includes html, "<ul>"
    assert_includes html, "<li>Item one</li>"
    assert_includes html, "<li>Item two</li>"
    assert_includes html, "<li>Item three</li>"
  end

  test 'converts markdown headers to HTML' do
    html = Adapters::EmailFormatter.to_html("# Hello\n\nSome text")

    assert_includes html, "<h1"
    assert_includes html, "Hello"
    assert_includes html, "<p>Some text</p>"
  end

  test 'wraps output in HTML email template' do
    html = Adapters::EmailFormatter.to_html("Hello")

    assert_includes html, "<!DOCTYPE html>"
    assert_includes html, "<html>"
    assert_includes html, "</html>"
    assert_includes html, "font-family"
  end

  test 'converts plain text paragraphs' do
    html = Adapters::EmailFormatter.to_html("First paragraph.\n\nSecond paragraph.")

    assert_includes html, "<p>First paragraph.</p>"
    assert_includes html, "<p>Second paragraph.</p>"
  end

  test 'converts markdown links to HTML' do
    html = Adapters::EmailFormatter.to_html("Visit [Example](https://example.com)")

    assert_includes html, '<a href="https://example.com">Example</a>'
  end

  test 'handles empty string' do
    html = Adapters::EmailFormatter.to_html("")

    assert_includes html, "<!DOCTYPE html>"
  end
end
