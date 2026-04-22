# frozen_string_literal: true

require "find"

class ExpirePageCacheJob < ApplicationJob
  queue_as :default

  TTL = 5.minutes

  def perform
    root = Rails.application.config.action_controller.page_cache_directory.to_s
    return if root.empty? || !File.directory?(root)

    cutoff = TTL.ago
    Find.find(root) do |path|
      next if path == root
      stat = File.lstat(path)
      next unless stat.file?
      File.unlink(path) if stat.mtime < cutoff
    rescue Errno::ENOENT
      next
    end
  end
end
