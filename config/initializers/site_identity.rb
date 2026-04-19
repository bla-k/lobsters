# frozen_string_literal: true
#
# Fork identity for Hackt News. Kept out of config/application.rb so upstream
# lobsters merges touch zero tracked lobsters files. Applies in every
# environment (dev, test, prod) so fresh clones work without extra setup.

class << Rails.application
  def domain
    "hackt.news"
  end

  def name
    "Hackt News"
  end

  def og_description
    "Hackt News is the community news aggregator for HACKT - The Hacklab of Catania."
  end
end
