# typed: false

class MailingListMailer < ApplicationMailer
  EMAIL_WIDTH = 72

  def new_story(story, user)
    @story = story
    @user = user

    headers "Message-Id" => @story.mailing_list_message_id,
      "X-Is-Author" => @story.user_is_author?.to_s,
      "List-Id" => list_id,
      "List-Unsubscribe" => list_unsubscribe_url,
      "X-BeenThere" => list_address(user),
      "Precedence" => "list"

    mail(
      from: from_for(story.user, nil),
      reply_to: list_address(user),
      to: user.email,
      subject: story_subject(story),
      date: story.created_at
    )
  end

  def new_comment(comment, user)
    @comment = comment
    @user = user

    headers "Message-Id" => @comment.mailing_list_message_id,
      "List-Id" => list_id,
      "List-Unsubscribe" => list_unsubscribe_url,
      "Precedence" => "list",
      "In-Reply-To" => "<#{comment.parent_comment&.mailing_list_message_id || comment.story.mailing_list_message_id}>",
      "References" => ([comment.story.mailing_list_message_id] +
        comment.parents.map(&:mailing_list_message_id))
        .map { |r| "<#{r}>" }.join(" ")

    mail(
      from: from_for(comment.user, comment.hat),
      reply_to: list_address(user),
      to: user.email,
      subject: story_subject(comment.story, "Re: "),
      date: comment.created_at
    )
  end

  private

  def from_for(author, hat)
    bits = [author.username]
    bits << "(#{hat.hat})" if hat
    bits << "via #{Rails.application.name}"
    display = bits.join(" ")
    # Quote the display name; the actual address must be an authenticated
    # sender to pass SPF/DKIM (we can't spoof #{username}@#{domain} upstream-style).
    "\"#{display.gsub('"', '\\"')}\" <noreply@#{Rails.application.domain}>"
  end

  def list_address(user)
    "#{Rails.application.shortname}-#{user.mailing_list_token}@#{Rails.application.domain}"
  end

  def list_id
    "#{Rails.application.name} <#{Rails.application.shortname}.#{Rails.application.domain}>"
  end

  def list_unsubscribe_url
    "<#{Rails.application.root_url}settings>"
  end

  def story_subject(story, prefix = "")
    ss = +"#{prefix}#{story.title}"
    story.tags.sort_by(&:tag).each { |t| ss << " [#{t.tag}]" }
    ss
  end
end
