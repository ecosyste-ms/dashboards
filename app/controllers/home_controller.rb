class HomeController < ApplicationController
  include Pagy::Backend

  def index
    @scope = Project.with_repository.active

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:owner].present?
      @scope = @scope.owner(params[:owner])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'created_at')
      if params[:order] == 'asc'
        @scope = @scope.order(sort.asc.nulls_last)
      else
        @scope = @scope.order(sort.desc.nulls_last)
      end
    else
      @scope = @scope.order('created_at DESC')
    end

    @pagy, @projects = pagy(@scope)
  end
end
