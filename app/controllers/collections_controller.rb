class CollectionsController < ApplicationController
  skip_before_action :set_cache_headers
  before_action :set_period_vars, only: [:show, :engagement, :productivity, :finance, :responsiveness, :security, :projects]

  before_action :authenticate_user!

  before_action :set_collection_with_visibility_check, except: [:index, :new, :create]
  before_action :redirect_if_syncing, only: [:show, :adoption, :engagement, :dependencies, :productivity, :finance, :responsiveness, :packages, :projects, :security]
  
  rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

  def index
    scope = current_user.collections
    @pagy, @collections = pagy(scope)
  end

  def show
    @range = range
    @period = period
    @top_package = @collection.packages.order_by_rankings.first
    
    # Load engagement metrics
    issues_scope = @collection.issues
    @active_contributors_last_period = issues_scope.between(@last_period_range.begin, @last_period_range.end).group(:user).count.length
    @active_contributors_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).group(:user).count.length
    
    @contributions_last_period = issues_scope.between(@last_period_range.begin, @last_period_range.end).count
    @contributions_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).count
    
    @contributor_role_breakdown_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).group(:author_association).count.sort_by { |_role, count| -count }.to_h
    
    # Load finance metrics
    collective_ids = @collection.unique_collective_ids
    if collective_ids.any?
      transactions = Transaction.where(collective_id: collective_ids)
      
      @payments_this_period = transactions.expenses.between(@this_period_range.begin, @this_period_range.end).count
      @payments_last_period = transactions.expenses.between(@last_period_range.begin, @last_period_range.end).count
      
      # Calculate reimbursements for show page
      @reimbursements_this_period = transactions.reimbursements
        .between(@this_period_range.begin, @this_period_range.end)
        .sum(:amount)
      
      @reimbursements_last_period = transactions.reimbursements
        .between(@last_period_range.begin, @last_period_range.end)
        .sum(:amount)
      
      # Calculate balance (donations minus expenses) for overview page
      donations_total_this = transactions.donations.between(@this_period_range.begin, @this_period_range.end).sum(:amount)
      expenses_total_this = transactions.expenses.between(@this_period_range.begin, @this_period_range.end).sum(:amount)
      @balance_this_period = donations_total_this - expenses_total_this
      
      donations_total_last = transactions.donations.between(@last_period_range.begin, @last_period_range.end).sum(:amount)
      expenses_total_last = transactions.expenses.between(@last_period_range.begin, @last_period_range.end).sum(:amount)
      @balance_last_period = donations_total_last - expenses_total_last
      
      # Amount spent and received for overview page
      @amount_spent_this_period = expenses_total_this
      @amount_spent_last_period = expenses_total_last
      
      @amount_received_this_period = donations_total_this
      @amount_received_last_period = donations_total_last
    else
      @payments_this_period = @payments_last_period = 0
      @reimbursements_this_period = @reimbursements_last_period = 0
      @balance_this_period = @balance_last_period = 0
      @amount_spent_this_period = @amount_spent_last_period = 0
      @amount_received_this_period = @amount_received_last_period = 0
    end
    
    # Load productivity metrics
    @tags_last_period = @collection.tags.between(@last_period_range.begin, @last_period_range.end).count
    @tags_this_period = @collection.tags.between(@this_period_range.begin, @this_period_range.end).count
    
    @open_isues_last_period = issues_scope.issue.open_between(@last_period_range.begin, @last_period_range.end).count
    @open_isues_this_period = issues_scope.issue.open_between(@this_period_range.begin, @this_period_range.end).count
    
    @open_prs_last_period = issues_scope.pull_request.open_between(@last_period_range.begin, @last_period_range.end).count
    @open_prs_this_period = issues_scope.pull_request.open_between(@this_period_range.begin, @this_period_range.end).count
    
    # Load new PRs data for overview page
    @new_prs_this_period = issues_scope.pull_request.between(@this_period_range.begin, @this_period_range.end).count
    @new_prs_last_period = issues_scope.pull_request.between(@last_period_range.begin, @last_period_range.end).count
    
    # Generate time series data for new PRs chart
    if @range == 'year'
      @new_prs_per_period = issues_scope.pull_request.group_by_year(:created_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
    else
      @new_prs_per_period = issues_scope.pull_request.group_by_month(:created_at, format: '%b', last: 6, expand_range: true, default_value: 0).count
    end
    
    # Load committers stats
    @committers_this_period = @collection.commits.between(@this_period_range.begin, @this_period_range.end).select(:author).distinct.count
    @committers_last_period = @collection.commits.between(@last_period_range.begin, @last_period_range.end).select(:author).distinct.count
    
    # Load unique authors metrics
    @unique_issue_authors_this_period = issues_scope.issue.between(@this_period_range.begin, @this_period_range.end).distinct.count(:user)
    @unique_issue_authors_last_period = issues_scope.issue.between(@last_period_range.begin, @last_period_range.end).distinct.count(:user)
    
    @unique_pr_authors_this_period = issues_scope.pull_request.between(@this_period_range.begin, @this_period_range.end).distinct.count(:user)
    @unique_pr_authors_last_period = issues_scope.pull_request.between(@last_period_range.begin, @last_period_range.end).distinct.count(:user)
    
    # Load responsiveness metrics
    @time_to_close_issues_last_period = (issues_scope.issue.closed_between(@last_period_range.begin, @last_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_issues_last_period = @time_to_close_issues_last_period.round(1)
    
    @time_to_close_issues_this_period = (issues_scope.issue.closed_between(@this_period_range.begin, @this_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_issues_this_period = @time_to_close_issues_this_period.round(1)
    
    @time_to_close_prs_last_period = (issues_scope.pull_request.closed_between(@last_period_range.begin, @last_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_prs_last_period = @time_to_close_prs_last_period.round(1)
    
    @time_to_close_prs_this_period = (issues_scope.pull_request.closed_between(@this_period_range.begin, @this_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_prs_this_period = @time_to_close_prs_this_period.round(1)
  end

  def syncing
    # Don't redirect if sync is complete - the page will handle both states
    # The redirect_if_syncing before_action handles showing syncing view when needed
    
    # Automatically recover if there are pending projects but nothing queued
    Rails.logger.info "Syncing page loaded for collection #{@collection.id}"
    Rails.logger.info "Collection import_status: #{@collection.import_status}, sync_status: #{@collection.sync_status}"
    Rails.logger.info "Checking if recovery needed..."
    
    if @collection.has_pending_but_nothing_queued?
      Rails.logger.info "Recovery needed - attempting to recover stuck sync"
      recovered = @collection.recover_stuck_sync!
      Rails.logger.info "Recovery result: #{recovered}"
    else
      Rails.logger.info "No recovery needed"
    end
  end

  def new
    @collection = current_user.collections.build
    # Pre-fill with GitHub URL if provided
    if params[:github_url].present?
      # For GitHub organization collections, set github_organization_url
      if params[:collection_type] == 'github'
        @collection.github_organization_url = params[:github_url]
      else
        @collection.url = params[:github_url]
      end
      # Try to extract a name from the URL
      if params[:github_url].include?('github.com/')
        org_name = params[:github_url].split('github.com/').last.split('/').first
        @collection.name = org_name if org_name.present?
      end
      # Default to public visibility when coming from a 404 redirect
      @collection.visibility = 'public'
    end
  end

  def create
    @collection = current_user.collections.build(collection_params)
    
    # Handle file upload for dependency_file
    if params[:collection][:dependency_file].respond_to?(:read)
      @collection.dependency_file = params[:collection][:dependency_file].read
    end
    
    if @collection.save
      # Trigger async import with ActionCable updates
      @collection.import_projects_async
      redirect_to clean_collection_path(@collection), notice: 'Collection was successfully created.'
    else
      flash.now[:alert] = @collection.errors.full_messages.to_sentence
      render :new
    end
  end

  def edit
    return unless require_owner!
  end

  def update
    return unless require_owner!
    
    # Handle file upload for dependency_file
    if params[:collection][:dependency_file].respond_to?(:read)
      params[:collection][:dependency_file] = params[:collection][:dependency_file].read
    end
    
    if @collection.update(collection_params)
      redirect_to clean_collection_path(@collection), notice: 'Collection was successfully updated.'
    else
      render :edit
    end
  end

  def destroy
    return unless require_owner!
    @collection.destroy
    redirect_to collections_path, notice: 'Collection was successfully deleted.'
  end

  def adoption
    @top_package = @collection.packages.order_by_rankings.first
  end

  def engagement
    # Apply bot filtering based on params
    issues_scope = @collection.issues
    issues_scope = issues_scope.human if params[:exclude_bots] == 'true'
    issues_scope = issues_scope.bot if params[:only_bots] == 'true'

    @active_contributors_last_period = issues_scope.between(@last_period_range.begin, @last_period_range.end).group(:user).count.length
    @active_contributors_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).group(:user).count.length

    @contributions_last_period = issues_scope.between(@last_period_range.begin, @last_period_range.end).count
    @contributions_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).count

    @issue_authors_last_period = issues_scope.between(@last_period_range.begin, @last_period_range.end).group(:user).count.length
    @issue_authors_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).group(:user).count.length

    @pr_authors_last_period = issues_scope.pull_request.between(@last_period_range.begin, @last_period_range.end).group(:user).count.length
    @pr_authors_this_period = issues_scope.pull_request.between(@this_period_range.begin, @this_period_range.end).group(:user).count.length

    @contributor_role_breakdown_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).group(:author_association).count.sort_by { |_role, count| -count }.to_h

    @all_time_contributors = issues_scope.group(:user).count.length

    if @range == 'year'
      @contributions_per_period = issues_scope.group_by_year(:created_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
    else
      @contributions_per_period = issues_scope.group_by_month(:created_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
    end
  end

  def dependencies
    # Use cached dependency counts for performance
    @direct_dependencies = @collection.direct_dependencies_count
    @development_dependencies = @collection.development_dependencies_count  
    @transitive_dependencies = @collection.transitive_dependencies_count

    # Only load full dependency data if we need to display the table
    @direct_deps = @collection.direct_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }
    @development_deps = @collection.development_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }
    @transitive_deps = @collection.transitive_dependencies.uniq { |dep| dep['package_name'] || dep['name'] }
    
    # Create lookup sets for faster type checking
    @direct_dep_names = Set.new(@direct_deps.map { |dep| dep['package_name'] || dep['name'] })
    @development_dep_names = Set.new(@development_deps.map { |dep| dep['package_name'] || dep['name'] })
    
    # Pre-calculate usage counts for performance
    @dependency_usage_counts = {}
    @collection.projects.each do |project|
      project.all_dependencies.each do |dep|
        package_name = dep['package_name'] || dep['name']
        @dependency_usage_counts[package_name] ||= 0
        @dependency_usage_counts[package_name] += 1
      end
    end
  end

  def productivity
    # Apply bot filtering based on params
    issues_scope = @collection.issues
    issues_scope = issues_scope.human if params[:exclude_bots] == 'true'
    issues_scope = issues_scope.bot if params[:only_bots] == 'true'

    @commits_last_period = @collection.commits.between(@last_period_range.begin, @last_period_range.end).count
    @commits_this_period = @collection.commits.between(@this_period_range.begin, @this_period_range.end).count

    @tags_last_period = @collection.tags.between(@last_period_range.begin, @last_period_range.end).count
    @tags_this_period = @collection.tags.between(@this_period_range.begin, @this_period_range.end).count

    commits_last = @collection.commits.between(@last_period_range.begin, @last_period_range.end)
    commits_this = @collection.commits.between(@this_period_range.begin, @this_period_range.end)

    authors_last = commits_last.select(:author).distinct.count
    authors_this = commits_this.select(:author).distinct.count

    @avg_commits_per_author_last_period = authors_last.zero? ? 0 : (commits_last.count.to_f / authors_last).round(1)
    @avg_commits_per_author_this_period = authors_this.zero? ? 0 : (commits_this.count.to_f / authors_this).round(1)

    @new_issues_last_period = issues_scope.issue.between(@last_period_range.begin, @last_period_range.end).count
    @new_issues_this_period = issues_scope.issue.between(@this_period_range.begin, @this_period_range.end).count

    @open_isues_last_period = issues_scope.issue.open_between(@last_period_range.begin, @last_period_range.end).count
    @open_isues_this_period = issues_scope.issue.open_between(@this_period_range.begin, @this_period_range.end).count

    @advisories_last_period = @collection.advisories.between(@last_period_range.begin, @last_period_range.end).count
    @advisories_this_period = @collection.advisories.between(@this_period_range.begin, @this_period_range.end).count

    @new_prs_last_period = issues_scope.pull_request.between(@last_period_range.begin, @last_period_range.end).count
    @new_prs_this_period = issues_scope.pull_request.between(@this_period_range.begin, @this_period_range.end).count

    @open_prs_last_period = issues_scope.pull_request.open_between(@last_period_range.begin, @last_period_range.end).count
    @open_prs_this_period = issues_scope.pull_request.open_between(@this_period_range.begin, @this_period_range.end).count

    @merged_prs_last_period = issues_scope.pull_request.merged_between(@last_period_range.begin, @last_period_range.end).count
    @merged_prs_this_period = issues_scope.pull_request.merged_between(@this_period_range.begin, @this_period_range.end).count
    
    # Time series data for productivity chart (new issues and PRs opened)
    if @range == 'year'
      @new_issues_per_period = issues_scope.issue.group_by_year(:created_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
      @new_prs_per_period = issues_scope.pull_request.group_by_year(:created_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
    else
      @new_issues_per_period = issues_scope.issue.group_by_month(:created_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
      @new_prs_per_period = issues_scope.pull_request.group_by_month(:created_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
    end
  end

  def finance
    # Calculate summary statistics
    projects_with_funding = @collection.projects.select { |p| 
      p.collective.present? || p.github_sponsors.present? || p.other_funding_links.present? 
    }
    
    @projects_with_funding_count = projects_with_funding.count
    @unique_collectives_count = @collection.projects.select(&:collective).map(&:collective_url).compact.uniq.count
    @unique_github_sponsors_count = @collection.projects.select { |p| p.github_sponsors.present? }.count

    # Aggregate data for all unique collectives
    collective_ids = @collection.unique_collective_ids
    if collective_ids.any?
      transactions = Transaction.where(collective_id: collective_ids)

      @total_contributions_this_period = transactions.donations.between(@this_period_range.begin, @this_period_range.end).count
      @total_contributions_last_period = transactions.donations.between(@last_period_range.begin, @last_period_range.end).count

      @total_payments_this_period = transactions.expenses.between(@this_period_range.begin, @this_period_range.end).count
      @total_payments_last_period = transactions.expenses.between(@last_period_range.begin, @last_period_range.end).count

      @total_donors_this_period = transactions.donations.between(@this_period_range.begin, @this_period_range.end).group(:from_account).count.length
      @total_donors_last_period = transactions.donations.between(@last_period_range.begin, @last_period_range.end).group(:from_account).count.length

      @total_payees_this_period = transactions.expenses.between(@this_period_range.begin, @this_period_range.end).group(:to_account).count.length
      @total_payees_last_period = transactions.expenses.between(@last_period_range.begin, @last_period_range.end).group(:to_account).count.length
      
      # Calculate reimbursements (RECEIPT type expenses)
      @total_reimbursements_this_period = transactions.reimbursements
        .between(@this_period_range.begin, @this_period_range.end)
        .sum(:amount)
      
      @total_reimbursements_last_period = transactions.reimbursements
        .between(@last_period_range.begin, @last_period_range.end)
        .sum(:amount)
      
      # Calculate recurring donor percentage for all collectives combined
      donors_this_list = transactions.donations
        .between(@this_period_range.begin, @this_period_range.end)
        .distinct.pluck(:from_account)
      donors_last_list = transactions.donations
        .between(@last_period_range.begin, @last_period_range.end)
        .distinct.pluck(:from_account)
      
      recurring_donors_count = (donors_this_list & donors_last_list).count
      
      @total_recurring_donors_percentage_this = donors_this_list.any? ? 
        (recurring_donors_count.to_f / donors_this_list.count * 100).round(0) : 0
      
      # For last period, compare with period before that
      donors_before_last = transactions.donations
        .between(@last_period_range.begin - (@last_period_range.end - @last_period_range.begin), @last_period_range.begin)
        .distinct.pluck(:from_account)
      
      recurring_donors_last_count = (donors_last_list & donors_before_last).count
      @total_recurring_donors_percentage_last = donors_last_list.any? ? 
        (recurring_donors_last_count.to_f / donors_last_list.count * 100).round(0) : 0

      # Calculate balance (donations minus expenses)
      donations_total_this = transactions.donations.between(@this_period_range.begin, @this_period_range.end).sum(:amount)
      expenses_total_this = transactions.expenses.between(@this_period_range.begin, @this_period_range.end).sum(:amount)
      @total_balance_this_period = donations_total_this - expenses_total_this
      
      donations_total_last = transactions.donations.between(@last_period_range.begin, @last_period_range.end).sum(:amount)
      expenses_total_last = transactions.expenses.between(@last_period_range.begin, @last_period_range.end).sum(:amount)
      @total_balance_last_period = donations_total_last - expenses_total_last
    else
      @total_contributions_this_period = @total_contributions_last_period = 0
      @total_payments_this_period = @total_payments_last_period = 0
      @total_donors_this_period = @total_donors_last_period = 0
      @total_payees_this_period = @total_payees_last_period = 0
      @total_balance_this_period = @total_balance_last_period = 0
    end

    # Aggregate data for all unique GitHub Sponsors
    github_sponsors_projects = @collection.projects.select { |p| p.github_sponsors.present? }
    if github_sponsors_projects.any?
      @total_current_sponsors = github_sponsors_projects.sum(&:current_github_sponsors_count)
      @total_past_sponsors = github_sponsors_projects.sum(&:past_github_sponsors_count)
      @total_github_sponsors = github_sponsors_projects.sum(&:total_github_sponsors_count)
      @min_github_sponsorship = github_sponsors_projects.map(&:github_minimum_sponsorship_amount).compact.min
    else
      @total_current_sponsors = @total_past_sponsors = @total_github_sponsors = 0
      @min_github_sponsorship = nil
    end
  end

  def responsiveness
    # Apply bot filtering based on params
    issues_scope = @collection.issues
    issues_scope = issues_scope.human if params[:exclude_bots] == 'true'
    issues_scope = issues_scope.bot if params[:only_bots] == 'true'
    
    # Load unique authors metrics
    @unique_issue_authors_this_period = issues_scope.issue.between(@this_period_range.begin, @this_period_range.end).distinct.count(:user)
    @unique_issue_authors_last_period = issues_scope.issue.between(@last_period_range.begin, @last_period_range.end).distinct.count(:user)
    
    @unique_pr_authors_this_period = issues_scope.pull_request.between(@this_period_range.begin, @this_period_range.end).distinct.count(:user)
    @unique_pr_authors_last_period = issues_scope.pull_request.between(@last_period_range.begin, @last_period_range.end).distinct.count(:user)
    
    # Load merged PRs count
    @merged_prs_this_period = issues_scope.pull_request.merged_between(@this_period_range.begin, @this_period_range.end).count
    @merged_prs_last_period = issues_scope.pull_request.merged_between(@last_period_range.begin, @last_period_range.end).count
    
    # Load closed issues count
    @closed_issues_this_period = issues_scope.issue.closed_between(@this_period_range.begin, @this_period_range.end).count
    @closed_issues_last_period = issues_scope.issue.closed_between(@last_period_range.begin, @last_period_range.end).count

    @time_to_close_prs_last_period = (issues_scope.pull_request.closed_between(@last_period_range.begin, @last_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_prs_last_period = @time_to_close_prs_last_period.round(1)

    @time_to_close_prs_this_period = (issues_scope.pull_request.closed_between(@this_period_range.begin, @this_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_prs_this_period = @time_to_close_prs_this_period.round(1)

    @time_to_close_issues_last_period = (issues_scope.issue.closed_between(@last_period_range.begin, @last_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_issues_last_period = @time_to_close_issues_last_period.round(1)

    @time_to_close_issues_this_period = (issues_scope.issue.closed_between(@this_period_range.begin, @this_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_issues_this_period = @time_to_close_issues_this_period.round(1)
    
    # Time series data for responsiveness chart (issues closed and PRs merged)
    if @range == 'year'
      @closed_issues_per_period = issues_scope.issue.where.not(closed_at: nil).group_by_year(:closed_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
      @merged_prs_per_period = issues_scope.pull_request.where.not(merged_at: nil).group_by_year(:merged_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
    else
      @closed_issues_per_period = issues_scope.issue.where.not(closed_at: nil).group_by_month(:closed_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
      @merged_prs_per_period = issues_scope.pull_request.where.not(merged_at: nil).group_by_month(:merged_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
    end
  end

  def packages
    @pagy, @packages = pagy(@collection.packages.active.order_by_rankings)
  end

  def security
    # Date filtering using period ranges from set_period_vars
    advisories_scope = @collection.advisories
    project_ids = @collection.projects.pluck(:id)
    dependabot_scope = Issue.where(project_id: project_ids).dependabot.security_prs

    # Apply period filtering - use this_period_range for filtering data to current period
    advisories_scope = advisories_scope.where(published_at: @this_period_range)
    dependabot_scope = dependabot_scope.where(created_at: @this_period_range)

    @pagy, @advisories = pagy(advisories_scope.order('published_at DESC'))

    # Dependabot security data from all projects in collection
    @dependabot_security_issues = Issue.where(project_id: project_ids).dependabot.security_prs
    @dependabot_security_count = @dependabot_security_issues.count
    @dependabot_open_security = @dependabot_security_issues.open.count
    @dependabot_closed_security = @dependabot_security_issues.closed.count
    @dependabot_filtered_count = dependabot_scope.count

    # Time series data for chart
    if @range == 'year'
      @dependabot_security_per_period = dependabot_scope.group_by_year(:created_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
      @advisories_per_period = advisories_scope.group_by_year(:published_at, format: '%Y', last: 6, expand_range: true, default_value: 0).count
    else
      @dependabot_security_per_period = dependabot_scope.group_by_month(:created_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
      @advisories_per_period = advisories_scope.group_by_month(:published_at, format: '%b %Y', last: 6, expand_range: true, default_value: 0).count
    end

    @recent_dependabot_security = dependabot_scope.includes(:project).order('created_at DESC').limit(5)
    
    # Top projects with security issues
    @projects_with_security = @collection.projects
      .joins(:issues)
      .where(issues: { id: dependabot_scope.select(:id) })
      .select('projects.*, COUNT(issues.id) as security_count')
      .group('projects.id')
      .order('security_count DESC')
      .limit(5)
    
    # Count of distinct projects with security issues (for the stats card)
    @projects_with_security_count = @collection.projects
      .joins(:issues)
      .where(issues: { id: dependabot_scope.select(:id) })
      .distinct
      .count
  end

  def projects
    @projects = @collection.projects
    @top_package = @collection.packages.order_by_rankings.first
    issues_scope = @collection.issues

    @new_issues_last_period = issues_scope.issue.between(@last_period_range.begin, @last_period_range.end).count
    @new_issues_this_period = issues_scope.issue.between(@this_period_range.begin, @this_period_range.end).count

    @new_prs_this_period = issues_scope.pull_request.between(@this_period_range.begin, @this_period_range.end).count
    @new_prs_last_period = issues_scope.pull_request.between(@last_period_range.begin, @last_period_range.end).count

    @time_to_close_prs_last_period = (issues_scope.pull_request.closed_between(@last_period_range.begin, @last_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_prs_last_period = @time_to_close_prs_last_period.round(1)
    
    @time_to_close_prs_this_period = (issues_scope.pull_request.closed_between(@this_period_range.begin, @this_period_range.end)
      .average('EXTRACT(EPOCH FROM (closed_at - issues.created_at))') || 0) / 86400.0
    @time_to_close_prs_this_period = @time_to_close_prs_this_period.round(1)

    @active_contributors_last_period = issues_scope.between(@last_period_range.begin, @last_period_range.end).group(:user).count.length
    @active_contributors_this_period = issues_scope.between(@this_period_range.begin, @this_period_range.end).group(:user).count.length

    @pagy, @projects = pagy(@projects)
  end

  def meta
  end

  def sync
    # Clear any existing errors before starting new sync
    @collection.update(
      import_status: 'pending',
      sync_status: 'pending',
      last_error_message: nil,
      last_error_backtrace: nil,
      last_error_at: nil
    )
    
    @collection.import_projects_async
    flash[:notice] = 'Collection sync started'
    redirect_to clean_collection_path(@collection)
  end

  private

  def handle_not_found
    # Check if this looks like a GitHub organization URL
    if params[:id] && params[:id].include?('github.com/')
      # Build the GitHub org URL
      github_url = "https://#{params[:id]}"
      # Redirect to new collection form with the URL pre-filled and collection_type set to 'github'
      redirect_to new_collection_path(github_url: github_url, collection_type: 'github'), alert: "Collection not found. Create a new collection for this organization?"
    else
      # For non-GitHub URLs or other cases, show a generic 404
      raise ActiveRecord::RecordNotFound
    end
  end

  def collection_params
    params.require(:collection).permit(
      :name,
      :description,
      :url,
      :visibility,
      :github_organization_url,
      :collective_url,
      :github_repo_url,
      :dependency_file
    )
  end

  def set_period_vars
    @range = range
    @year = year
    @month = month
    @period_date = period_date
    @previous_year = @range == 'year' ? (params[:previous_year] || @year - 1).to_i : (params[:previous_year] || @year).to_i
    
    if @month
      previous_month_value = (params[:previous_month] || @month - 1).to_i
      if previous_month_value <= 0
        @previous_month = 12
        @previous_year = @previous_year - 1
      else
        @previous_month = previous_month_value
      end
    else
      @previous_month = nil
    end

    @this_period_range =
      if @range == 'year'
        @period_date.beginning_of_year..@period_date.end_of_year
      else
        @period_date.beginning_of_month..@period_date.end_of_month
      end

    @last_period_range =
      if @range == 'year'
        Date.new(@previous_year).beginning_of_year..Date.new(@previous_year).end_of_year
      else
        Date.new(@previous_year, @previous_month).beginning_of_month..Date.new(@previous_year, @previous_month).end_of_month
      end
  end

  def range
    params[:range].in?(%w[month year]) ? params[:range] : 'month'
  end

  def year
    (params[:year] || 1.month.ago.year).to_i
  end

  def month
    range == 'month' ? (params[:month] || 1.month.ago.month).to_i : nil
  end

  def period_date
    return Date.new(year) if range == 'year'
    Date.new(year, month)
  end

  def set_collection_with_visibility_check
    collection_id = params[:id] || params[:collection_id]
    @collection = Collection.includes(:projects).find_by_slug(collection_id) || Collection.includes(:projects).find_by_uuid(collection_id)
    raise ActiveRecord::RecordNotFound if @collection.nil?
    if @collection.visibility == 'private' && @collection.user != current_user
      # Return 404 directly for permission denied, bypassing handle_not_found
      head :not_found
    end
  end

  def require_owner!
    if @collection.user == current_user
      true
    else
      head :not_found
      false
    end
  end

  def redirect_if_syncing
    # Check if we have pending projects but nothing queued (stuck sync)
    if @collection.has_pending_but_nothing_queued?
      Rails.logger.info "Collection #{@collection.id} has pending projects but nothing queued - recovering..."
      recovered = @collection.recover_stuck_sync!
      Rails.logger.info "Recovery result: #{recovered}"
    end
    
    # Also check for general stuck syncs (syncing for too long)
    if @collection.sync_stuck?
      Rails.logger.info "Restarting stuck sync for collection #{@collection.id} (stuck for too long)"
      @collection.import_projects_async
    end
    
    render :syncing unless @collection.ready?
  end
end
