class BuildEpisodeJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  def perform(conversation_id, first_message_id, last_message_id)
    conversation = Conversation.find(conversation_id)
    Current.workspace = conversation.workspace

    return if Episode.where(conversation_id: conversation_id,
                            first_message_id: first_message_id,
                            last_message_id: last_message_id).exists?

    episode = Memory::EpisodeBuilder.new(
      conversation: conversation,
      first_message_id: first_message_id,
      last_message_id: last_message_id
    ).call

    if episode
      Rails.logger.info(
        "[Episode] Built episode #{episode.id} for conversation #{conversation.id} " \
        "(messages #{first_message_id}..#{last_message_id})"
      )
    end
  end
end
