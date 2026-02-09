class SessionsController < ApplicationController
  skip_before_action :set_cache_headers

  def create
    user = User.from_omniauth(request.env['omniauth.auth'])
    session[:user_id] = user.id
    Rails.logger.debug "Auth Hash: #{request.env['omniauth.auth'].inspect}"
    redirect_to(session.delete(:return_to) || root_path, notice: 'Signed in!')
  end

  def new
    
  end

  def destroy
    session[:user_id] = nil
    redirect_to root_path, notice: 'Signed out!'
  end

  def failure
    Rails.logger.warn "OmniAuth failure: #{params[:message]}"
    redirect_to root_path, alert: "Auth failed"
  end
end