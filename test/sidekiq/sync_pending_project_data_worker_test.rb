require 'test_helper'

class SyncPendingProjectDataWorkerTest < ActiveSupport::TestCase
  test "retries components that are still pending" do
    project = create(:project)
    Project.stubs(:find_by_id).with(project.id).returns(project)
    project.expects(:sync_issues).returns(:pending)
    project.expects(:sync_commits).returns(:complete)
    project.expects(:safe_broadcast_sync_update)
    SyncPendingProjectDataWorker.expects(:perform_in)
      .with(5.minutes, project.id, ['issues'], 1)

    SyncPendingProjectDataWorker.new.perform(project.id, %w[issues commits], 0)
  end

  test "does not retry completed components" do
    project = create(:project)
    Project.stubs(:find_by_id).with(project.id).returns(project)
    project.expects(:sync_issues).returns(:complete)
    project.expects(:safe_broadcast_sync_update)
    SyncPendingProjectDataWorker.expects(:perform_in).never

    SyncPendingProjectDataWorker.new.perform(project.id, ['issues'], 0)
  end

  test "retries components after a transient error" do
    project = create(:project)
    Project.stubs(:find_by_id).with(project.id).returns(project)
    project.expects(:sync_commits).returns(:error)
    project.expects(:safe_broadcast_sync_update)
    SyncPendingProjectDataWorker.expects(:perform_in)
      .with(5.minutes, project.id, ['commits'], 1)

    SyncPendingProjectDataWorker.new.perform(project.id, ['commits'], 0)
  end

  test "stops after the final retry" do
    project = create(:project)
    Project.stubs(:find_by_id).with(project.id).returns(project)
    project.expects(:sync_commits).returns(:pending)
    project.expects(:safe_broadcast_sync_update)
    SyncPendingProjectDataWorker.expects(:perform_in).never

    SyncPendingProjectDataWorker.new.perform(project.id, ['commits'], 2)
  end

  test "ignores unknown components" do
    project = create(:project)
    Project.stubs(:find_by_id).with(project.id).returns(project)
    project.expects(:safe_broadcast_sync_update).never
    project.expects(:public_send).never

    SyncPendingProjectDataWorker.new.perform(project.id, ['packages'], 0)
  end
end
