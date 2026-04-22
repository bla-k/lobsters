# frozen_string_literal: true

# Port of script/mail_new_activity.rb. Sends one email per (new item, subscribed
# user) pair. Cursors track the last processed story/comment id across ticks.
#
# Delivery is deferred to SolidQueue (deliver_later) so the recurring tick stays
# fast and per-email failures retry independently.
class MailNewActivityJob < ApplicationJob
  queue_as :default

  LAST_STORY_KEY = "mailing:last_story_id"
  LAST_COMMENT_KEY = "mailing:last_comment_id"
  LOOKBACK = 3.days
  EDIT_GRACE = 2.minutes

  def perform
    return if File.exist?(Rails.public_path.join("maintenance.html"))

    subscribers = User.where("mailing_list_mode > 0").select(&:is_active?)
    return if subscribers.empty?

    mail_new_stories(subscribers)
    mail_new_comments(subscribers)
  end

  private

  def mail_new_stories(subscribers)
    last_id = (Keystore.value_for(LAST_STORY_KEY) || Story.last&.id).to_i

    Story
      .where("id > ? AND is_deleted = ? AND created_at >= ?", last_id, false, LOOKBACK.ago)
      .order(:id)
      .each do |s|
        # Defensive: FillStoryTextCacheJob also populates this, but both run on
        # the same 5m cadence and order isn't guaranteed. Idempotent.
        StoryText.fill_cache!(s)

        subscribers.each do |u|
          next if (s.tags.map(&:id) & u.tag_filters.map(&:tag_id)).any?
          next if s.is_hidden_by_user?(u)

          MailingListMailer.new_story(s, u).deliver_later
        end

        last_id = s.id
      end

    Keystore.put(LAST_STORY_KEY, last_id)
  end

  def mail_new_comments(subscribers)
    last_id = (Keystore.value_for(LAST_COMMENT_KEY) || Comment.last&.id).to_i

    Comment
      .where(
        "id > ? AND is_deleted = ? AND is_moderated = ? AND created_at >= ?",
        last_id, false, false, LOOKBACK.ago
      )
      .order(:id)
      .each do |c|
        # Allow some time for recent edits before sending.
        break if (Time.current - c.last_edited_at) < EDIT_GRACE

        subscribers.each do |u|
          next if u.mailing_list_mode == 2 # stories only
          next if (c.story.tags.map(&:id) & u.tag_filters.map(&:tag_id)).any?
          next if c.story.is_hidden_by_user?(u)

          MailingListMailer.new_comment(c, u).deliver_later
        end

        last_id = c.id
      end

    Keystore.put(LAST_COMMENT_KEY, last_id)
  end
end
