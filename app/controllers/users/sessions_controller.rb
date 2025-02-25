module Users
  class SessionsController < Devise::SessionsController
    include ::ActionView::Helpers::DateHelper
    include SecureHeadersConcern
    include RememberDeviceConcern
    include Ial2ProfileConcern

    rescue_from ActionController::InvalidAuthenticityToken, with: :redirect_to_signin

    skip_before_action :session_expires_at, only: %i[active keepalive]
    skip_before_action :require_no_authentication, only: [:new]
    before_action :store_sp_metadata_in_session, only: [:new]
    before_action :check_user_needs_redirect, only: [:new]
    before_action :apply_secure_headers_override, only: [:new, :create]
    before_action :clear_session_bad_password_count_if_window_expired, only: [:create]

    def new
      analytics.track_event(
        Analytics::SIGN_IN_PAGE_VISIT,
        flash: flash[:alert],
        stored_location: session['user_return_to'],
      )

      @request_id = request_id_if_valid
      @ial = sp_session_ial
      super
    end

    def create
      track_authentication_attempt(auth_params[:email])

      return process_locked_out_session if session_bad_password_count_max_exceeded?
      return process_locked_out_user if current_user && user_locked_out?(current_user)

      throttle_password_failure = true
      self.resource = warden.authenticate!(auth_options)
      handle_valid_authentication
    ensure
      increment_session_bad_password_count if throttle_password_failure && !current_user
    end

    def destroy
      analytics.track_event(Analytics::LOGOUT_INITIATED, sp_initiated: false, oidc: false)
      super
    end

    def active
      response.headers['Etag'] = '' # clear etags to prevent caching
      session[:pinged_at] = now
      Rails.logger.debug(alive?: alive?, expires_at: expires_at)
      render json: { live: alive?, timeout: expires_at, remaining: remaining_session_time }
    end

    def keepalive
      response.headers['Etag'] = '' # clear etags to prevent caching
      session[:session_expires_at] = now + Devise.timeout_in if alive?
      analytics.track_event(Analytics::SESSION_KEPT_ALIVE) if alive?

      render json: { live: alive?, timeout: expires_at, remaining: remaining_session_time }
    end

    def timeout
      analytics.track_event(Analytics::SESSION_TIMED_OUT)
      request_id = sp_session[:request_id]
      sign_out
      flash[:info] = t(
        'notices.session_timedout',
        app_name: APP_NAME,
        minutes: IdentityConfig.store.session_timeout_in_minutes,
      )
      redirect_to root_url(request_id: request_id)
    end

    private

    def clear_session_bad_password_count_if_window_expired
      locked_at = session[:max_bad_passwords_at]
      window = IdentityConfig.store.max_bad_passwords_window_in_seconds
      return if locked_at.nil? || (locked_at + window) > Time.zone.now.to_i
      [:max_bad_passwords_at, :bad_password_count].each { |x| session.delete(x) }
    end

    def session_bad_password_count_max_exceeded?
      session[:bad_password_count].to_i >= IdentityConfig.store.max_bad_passwords
    end

    def increment_session_bad_password_count
      session[:bad_password_count] = session[:bad_password_count].to_i + 1
      return unless session_bad_password_count_max_exceeded?
      session[:max_bad_passwords_at] ||= Time.zone.now.to_i
    end

    def process_locked_out_session
      flash[:error] = t('errors.sign_in.bad_password_limit')
      redirect_to root_url(request_id: request_id)
    end

    def redirect_to_signin
      controller_info = 'users/sessions#create'
      analytics.track_event(Analytics::INVALID_AUTHENTICITY_TOKEN, controller: controller_info)
      sign_out
      flash[:error] = t('errors.invalid_authenticity_token')
      redirect_back fallback_location: new_user_session_url, allow_other_host: false
    end

    def check_user_needs_redirect
      if user_fully_authenticated?
        redirect_to signed_in_url
      elsif current_user
        sign_out
      end
    end

    def auth_params
      params.require(:user).permit(:email, :password, :request_id)
    end

    def process_locked_out_user
      presenter = TwoFactorAuthCode::MaxAttemptsReachedPresenter.new(
        'generic_login_attempts',
        current_user.decorate,
      )
      sign_out
      render_full_width('shared/_failure', locals: { presenter: presenter })
    end

    def handle_valid_authentication
      sign_in(resource_name, resource)
      cache_active_profile(auth_params[:password])
      add_sp_cost(:digest)
      create_user_event(:sign_in_before_2fa)
      update_sp_return_logs_with_user(current_user.id)
      EmailAddress.update_last_sign_in_at_on_user_id_and_email(
        user_id: current_user.id,
        email: auth_params[:email],
      )
      redirect_to next_url_after_valid_authentication
    end

    def now
      @now ||= Time.zone.now
    end

    def update_sp_return_logs_with_user(user_id)
      sp_session = session[:sp]
      if sp_session
        Db::SpReturnLog.update_user(
          request_id: sp_session[:request_id],
          user_id: user_id,
        )
      end
    end

    def expires_at
      session[:session_expires_at]&.to_datetime || (now - 1)
    end

    def remaining_session_time
      expires_at.to_i - Time.zone.now.to_i
    end

    def alive?
      return false unless session && expires_at
      session_alive = expires_at > now
      current_user.present? && session_alive
    end

    def track_authentication_attempt(email)
      user = User.find_with_email(email) || AnonymousUser.new

      properties = {
        success: user_signed_in_and_not_locked_out?(user),
        user_id: user.uuid,
        user_locked_out: user_locked_out?(user),
        stored_location: session['user_return_to'],
        sp_request_url_present: sp_session[:request_url].present?,
        remember_device: remember_device_cookie.present?,
      }

      analytics.track_event(Analytics::EMAIL_AND_PASSWORD_AUTH, properties)
    end

    def user_signed_in_and_not_locked_out?(user)
      return false unless current_user
      !user_locked_out?(user)
    end

    def user_locked_out?(user)
      UserDecorator.new(user).locked_out?
    end

    def store_sp_metadata_in_session
      return if sp_session[:issuer] || request_id.blank?
      StoreSpMetadataInSession.new(session: session, request_id: request_id).call
    end

    def request_id
      params.fetch(:request_id, '')
    end

    def next_url_after_valid_authentication
      if pending_account_reset_request.present?
        account_reset_pending_url
      elsif current_user.accepted_rules_of_use_still_valid?
        user_two_factor_authentication_url
      else
        rules_of_use_url
      end
    end

    def pending_account_reset_request
      AccountReset::FindPendingRequestForUser.new(
        current_user,
      ).call
    end

    LETTERS_AND_DASHES = /\A[a-z0-9\-]+\Z/i.freeze

    def request_id_if_valid
      request_id = (params[:request_id] || sp_session[:request_id]).to_s

      request_id if LETTERS_AND_DASHES.match?(request_id)
    end
  end
end
