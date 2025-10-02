module ApplicationHelper
  include Pagy::Frontend

  def meta_title
    [@meta_title, 'Ecosyste.ms: Dashboards'].compact.join(' | ')
  end

  def meta_description
    @meta_description || app_description
  end

  def app_name
    "Dashboards"
  end

  def app_description
    'A web application to visualize and manage open source project data from the Ecosyste.ms API.'
  end

  def obfusticate_email(email)
    return unless email
    email.split('@').map do |part|
      # part.gsub(/./, '*') 
      part.tap { |p| p[1...-1] = "****" }
    end.join('@')
  end

  def period_label(year, month = nil)
    return year.to_s unless month
    Date.new(year, month).strftime("%B %Y")
  rescue ArgumentError
    "Invalid date"
  end

  def distance_of_time_in_words_if_present(time)
    return 'N/A' unless time
    distance_of_time_in_words(time)
  end

  def diff_class(count)
    count > 0 ? 'text-success' : 'text-danger'
  end

  def download_period(downloads_period)
    case downloads_period
    when "last-month"
      "last month"
    when "total"
      "total"
    end
  end

  def period_name(start_date, end_date)
    case @period
    when :day
      start_date.strftime("%A, %B %e, %Y")
    when :week
      start_date.strftime("%B %e, %Y") + " - " + end_date.strftime("%B %e, %Y")
    when :month
      start_date.strftime("%B %Y")
    when :year
      start_date.strftime("%Y")
    end
  end

  def current_period_name
    period_name(@start_date, @end_date)
  end

  def previous_period_name
    period_name(previous_period_start_date, previous_period_end_date)
  end

  def next_period_name
    period_name(next_period_start_date, next_period_end_date)
  end

  def previous_period_start_date
    case @period
    when :day
      @start_date - 1.day
    when :week
      @start_date - 1.week
    when :month
      @start_date - 1.month
    when :year
      @start_date - 1.year
    end
  end

  def previous_period_end_date
    case @period
    when :day
      @end_date - 1.day
    when :week
      @end_date - 1.week
    when :month
      @end_date - 1.month
    when :year
      @end_date - 1.year
    end
  end

  def next_period_start_date
    case @period
    when :day
      @start_date + 1.day
    when :week
      @start_date + 1.week
    when :month
      @start_date + 1.month
    when :year
      @start_date + 1.year
    end
  end

  def next_period_end_date
    case @period
    when :day
      @end_date + 1.day
    when :week
      @end_date + 1.week
    when :month
      @end_date + 1.month
    when :year
      @end_date + 1.year
    end
  end

  def next_period_valid?
    next_period_start_date < Time.now && next_period_end_date < Time.now
  end

  def severity_class(severity)
    case severity.downcase
    when 'low'
      'success'
    when 'moderate'
      'warning'
    when 'high'
      'danger'
    when 'critical'
      'dark'
    else
      'info'
    end
  end

  def convert_purl_type(purl_type)
    case purl_type
    when "actions"
      "githubactions"
    when "elpa"
      "melpa"
    when "go"
      "golang"
    when "homebrew"
      "brew"
    when "packagist"
      "composer"
    when "rubygems"
      "gem"
    when "swiftpm"
      "swift"
    else
      purl_type
    end
  end

  def project_path_with_collection(project, action = nil, collection = nil)
    collection ||= @collection
    
    base_path = if collection
      collection_project_path(collection, project)
    else
      project_path(project)
    end
    
    # Get current request parameters (excluding controller/action/id)
    current_params = request.query_parameters.except('controller', 'action', 'id', 'collection_id')
    
    if action.nil?
      # If no action is specified, remove the tab parameter entirely (overview is the default)
      current_params = current_params.except('tab')
    end
    
    if action || current_params.any?
      # Parse existing query string and merge with current params
      uri = URI.parse(base_path)
      params = Rack::Utils.parse_query(uri.query).merge(current_params.stringify_keys)
      params['tab'] = action if action
      uri.query = params.to_query unless params.empty?
      uri.to_s
    else
      base_path
    end
  end

  def current_url_with_params(new_params)
    # Build URL using current path (preserves encoding) and merge query params
    uri = URI.parse(request.url)
    current_params = Rack::Utils.parse_query(uri.query || '')
    merged_params = current_params.merge(new_params.stringify_keys)

    uri.query = merged_params.any? ? merged_params.to_query : nil
    uri.to_s
  end

  def bootstrap_icon(symbol, options = {})
    return "" if symbol.nil?
    icon = BootstrapIcons::BootstrapIcon.new(symbol, options)
    content_tag(:svg, icon.path.html_safe, icon.options)
  end
end
