class ApplicationController < ActionController::Base
  # protect_from_forgery with: :exception
  include Pagy::Backend

  before_action :set_cache_headers

  def default_url_options(options = {})
    Rails.env.production? ? { :protocol => "https" }.merge(options) : options
  end

  def set_cache_headers(browser_ttl: 5.minutes, cdn_ttl: 6.hours)
    return unless request.get?
    return if logged_in?
    response.cache_control.merge!(
      public: true,
      max_age: browser_ttl.to_i,
      stale_while_revalidate: cdn_ttl.to_i,
      stale_if_error: 1.day.to_i
    )
    response.cache_control[:extras] = ["s-maxage=#{cdn_ttl.to_i}"]
  end

  helper_method :current_user

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def authenticate_user!
    unless current_user
      session[:return_to] = request.fullpath if request.get?
      redirect_to login_path, alert: "You must be logged in to access this section"
    end
  end

  helper_method :logged_in?
  def logged_in?
    current_user.present?
  end

  def sanitize_sort(allowed_columns, default: 'updated_at')
    sort_param = params[:sort].presence || default
    sql = allowed_columns[sort_param] || allowed_columns[default] || default
    Arel.sql(sql)
  end

  def range
    (params[:range].presence || 30).to_i
  end

  def period
    case range
    when 0..30
      (params[:period].presence || 'day').to_sym
    when 31..90
      (params[:period].presence || 'week').to_sym
    when 91..366
      (params[:period].presence || 'month').to_sym
    else
      (params[:period].presence || 'month').to_sym
    end
  end

  def timescale
    case period
    when :day
      30 # 1 month
    when :week
      7*12 # 12 weeks
    when :month
      366 # 12 months
    when :year
      365*3 # 3 years
    end
  end

  def interval
    case period
    when :day
      1.hour
    when :week
      1.day
    when :month
      1.day
    when :year
      1.month
    end
  end

  def start_date
    (params[:start_date].presence && params[:start_date].to_datetime) || default_start_date
  end

  def end_date
    (params[:end_date].presence && params[:end_date].to_datetime) || default_end_date
  end

  helper_method :default_end_date
  def default_end_date    
    case period
    when :day
      1.day.ago.end_of_day
    when :week
      1.week.ago.end_of_week
    when :month
      1.month.ago.end_of_month
    when :year
      1.year.ago.end_of_year
    end
  end

  helper_method :default_start_date
  def default_start_date
    case period
    when :day
      1.day.ago.beginning_of_day
    when :week
      1.week.ago.beginning_of_week
    when :month
      1.month.ago.beginning_of_month
    when :year
      1.year.ago.beginning_of_year
    end
  end

  # Custom URL generation methods that don't encode forward slashes
  # These methods generate clean URLs for projects with forward slashes in slugs
  helper_method :clean_project_path, :clean_collection_path, :clean_collection_project_path
  
  def clean_project_path(project)
    return project_path(project) if project.slug.blank?
    
    if project.slug.include?('..')
      Rails.logger.warn "Potential path traversal attempt: #{project.slug}"
      return project_path(project)
    end
    
    "/projects/#{project.slug}"
  end


  def clean_collection_project_path(collection, project)
    return collection_project_path(collection, project) if project.slug.blank?
    
    if project.slug.include?('..')
      Rails.logger.warn "Potential path traversal attempt: #{project.slug}"
      return collection_project_path(collection, project)
    end
    
    "/collections/#{collection.to_param}/projects/#{project.slug}"
  end

  def clean_collection_path(collection, query_params = {})
    return collection_path(collection, query_params) if collection.slug.blank?

    if collection.slug.include?('..')
      Rails.logger.warn "Potential path traversal attempt: #{collection.slug}"
      return collection_path(collection, query_params)
    end

    # Build clean path manually but use Rails' parameter handling for security
    path = "/collections/#{CGI.escape(collection.slug)}"

    if query_params.present?
      # Use Rails' to_query method for safe parameter encoding
      query_string = query_params.to_query
      path = "#{path}?#{query_string}" if query_string.present?
    end

    path
  end
end
