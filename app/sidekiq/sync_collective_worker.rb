class SyncCollectiveWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: 'opencollective', retry: 3

  def perform(collective_id)
    Collective.find_by_id(collective_id).try(:sync)
  end
end