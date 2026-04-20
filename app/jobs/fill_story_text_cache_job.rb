# frozen_string_literal: true

class FillStoryTextCacheJob < ApplicationJob
  queue_as :default

  CURSOR_KEY = "story_text:last_story_id"
  LOOKBACK = 3.days

  def perform
    last_id = (Keystore.value_for(CURSOR_KEY) || Story.last&.id).to_i

    Story
      .where("id > ? AND is_deleted = ? AND created_at >= ?", last_id, false, LOOKBACK.ago)
      .order(:id)
      .each do |s|
        StoryText.fill_cache!(s)
        last_id = s.id
      end

    Keystore.put(CURSOR_KEY, last_id)
  end
end
