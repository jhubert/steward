module Adapters
  class Background < Base
    def normalize(raw_params) = {}
    def send_reply(conversation, message) = nil
    def send_typing(conversation) = nil
    def channel = "background"
  end
end
