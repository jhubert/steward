module Adapters
  class EmailFormatter
    def self.to_html(text)
      body_html = Kramdown::Document.new(text).to_html
      wrap_in_template(body_html)
    end

    def self.wrap_in_template(body_html)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="margin: 0; padding: 0; background-color: #ffffff;">
          <div style="max-width: 600px; margin: 0 auto; padding: 20px; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.6; color: #1a1a1a;">
            #{body_html}
          </div>
        </body>
        </html>
      HTML
    end

    private_class_method :wrap_in_template
  end
end
