class Api::V1::ProjectsController < Api::V1::ApplicationController
  skip_before_action :set_cache_headers, only: [:ping]
  skip_before_action :set_api_cache_headers, only: [:ping]

  def index
    @projects = Project.all.where.not(last_synced_at: nil).includes(:collective, :tags)
    @pagy, @projects = pagy(@projects)
  end

  def show
    @project = Project.find_by!(slug: params[:id])
  end

  def lookup
    @project = Project.find_by(url: params[:url].downcase)
    raise ActiveRecord::RecordNotFound unless @project
  end

  def ping
    @project = Project.find_by!(slug: params[:id])
    @project.sync_async
    render json: { message: 'pong' }
  end
  
  def issues
    @project = Project.find_by!(slug: params[:id])
    @issues = @project.issues.order(created_at: :desc)
    @pagy, @issues = pagy(@issues)
  end
  
  def releases
    @project = Project.find_by!(slug: params[:id])
    @releases = @project.tags.displayable.order(published_at: :desc)
    @pagy, @releases = pagy(@releases)
  end
  
  def commits
    @project = Project.find_by!(slug: params[:id])
    @commits = @project.commits.order(timestamp: :desc)
    @pagy, @commits = pagy(@commits)
  end
  
  def packages
    @project = Project.find_by!(slug: params[:id])
    @packages = @project.packages.order(name: :asc)
  end
  
  def advisories
    @project = Project.find_by!(slug: params[:id])
    @advisories = @project.advisories.order(published_at: :desc)
    @pagy, @advisories = pagy(@advisories)
  end
end