class Api::V1::CollectionsController < Api::V1::ApplicationController
  def index
    @collections = Collection.visible  # Only show public collections

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Collection.sortable_columns, default: 'collections.updated_at')
      if params[:order] == 'asc'
        @collections = @collections.order(sort.asc.nulls_last)
      else
        @collections = @collections.order(sort.desc.nulls_last)
      end
    end

    @pagy, @collections = pagy_countless(@collections)
  end

  def show
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
    end
  end

  def lookup
    @collection = Collection.visible.find_by(slug: params[:slug])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
    end
  end

  def projects
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
      return
    end
    
    @projects = @collection.projects
    
    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'projects.updated_at')
      if params[:order] == 'asc'
        @projects = @projects.order(sort.asc.nulls_last)
      else
        @projects = @projects.order(sort.desc.nulls_last)
      end
    end

    @pagy, @projects = pagy_countless(@projects)
  end

  def issues
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
      return
    end
    @issues = Issue.where(project: @collection.projects).order(created_at: :desc)
    @pagy, @issues = pagy(@issues)
  end

  def releases
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
      return
    end
    @releases = Tag.where(project: @collection.projects).order(published_at: :desc)
    @pagy, @releases = pagy(@releases)
  end

  def commits
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
      return
    end
    @commits = Commit.where(project: @collection.projects).order(timestamp: :desc)
    @pagy, @commits = pagy(@commits)
  end

  def packages
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
      return
    end
    @packages = Package.where(project: @collection.projects).order(created_at: :desc)
    @pagy, @packages = pagy(@packages)
  end

  def advisories
    @collection = Collection.visible.find_by(slug: params[:id])
    if @collection.nil?
      render json: { error: 'Collection not found' }, status: :not_found
      return
    end
    @advisories = Advisory.where(project: @collection.projects).order(published_at: :desc)
    @pagy, @advisories = pagy(@advisories)
  end
end