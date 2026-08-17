class SyncPendingProjectDataWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  RETRY_DELAYS = [1.minute, 5.minutes, 15.minutes].freeze
  COMPONENTS = %w[issues commits].freeze

  def self.schedule(project_id, components, attempt = 0)
    components = components & COMPONENTS
    delay = RETRY_DELAYS[attempt]
    return if components.empty? || delay.nil?

    perform_in(delay, project_id, components, attempt)
  end

  def perform(project_id, components, attempt = 0)
    project = Project.find_by_id(project_id)
    return unless project

    components = components & COMPONENTS
    return if components.empty?

    pending_components = components.reject do |component|
      project.public_send("sync_#{component}") == :complete
    end

    self.class.schedule(project_id, pending_components, attempt + 1)
    project.safe_broadcast_sync_update
  end
end
