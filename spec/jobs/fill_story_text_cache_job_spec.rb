require "rails_helper"

RSpec.describe FillStoryTextCacheJob, type: :job do
  let(:job) { described_class.new }

  before do
    allow(DiffBot).to receive(:get_story_text).and_return("diffbot body")
    Keystore.where(key: described_class::CURSOR_KEY).delete_all
  end

  describe "#perform" do
    it "creates a StoryText for each new story and advances the cursor" do
      a = create(:story)
      b = create(:story)
      Keystore.put(described_class::CURSOR_KEY, a.id - 1)

      job.perform

      expect(StoryText.where(id: [a.id, b.id]).count).to eq(2)
      expect(Keystore.value_for(described_class::CURSOR_KEY)).to eq(b.id)
    end

    it "skips deleted stories" do
      deleted = create(:story, :deleted)
      live = create(:story)
      Keystore.put(described_class::CURSOR_KEY, deleted.id - 1)

      job.perform

      expect(StoryText.where(id: deleted.id)).not_to exist
      expect(StoryText.where(id: live.id)).to exist
      expect(Keystore.value_for(described_class::CURSOR_KEY)).to eq(live.id)
    end

    it "ignores stories older than the lookback window" do
      old = create(:story)
      old.update_columns(created_at: 4.days.ago)
      Keystore.put(described_class::CURSOR_KEY, old.id - 1)

      job.perform

      expect(StoryText.where(id: old.id)).not_to exist
      expect(Keystore.value_for(described_class::CURSOR_KEY)).to eq(old.id - 1)
    end

    it "seeds and persists the cursor at Story.last when the cursor is unset" do
      earlier = create(:story)
      StoryText.create!(id: earlier.id, title: earlier.title, description: earlier.description, body: "seeded")
      later = create(:story)

      job.perform

      expect(StoryText.find(earlier.id).body).to eq("seeded")
      expect(StoryText.where(id: later.id)).not_to exist
      expect(Keystore.value_for(described_class::CURSOR_KEY)).to eq(later.id)
    end
  end
end
