# frozen_string_literal: true

class LoginsController < ApplicationController
  skip_before_action :signed_in_user
  skip_after_action :verify_authorized
  before_action :set_login, except: [:new, :create]
  before_action :set_user, except: [:new, :create]
  before_action :set_available_methods, except: [:new, :create]
  before_action :set_return_to

  layout "login"

  after_action only: [:new] do
    # Allow indexing login page
    response.delete_header("X-Robots-Tag")
  end

  # view to log in
  def new
    @return_to = url_from(params[:return_to])
    render "users/logout" if current_user

    @prefill_email = params[:email] if params[:email].present?
    @referral_program = Referral::Program.find_by_hashid(params[:referral]) if params[:referral].present?
  end

  # when you submit your email
  def create
    user = User.create_with(creation_method: :login).find_or_create_by!(email: params[:email])

    referral_program = Referral::Program.find_by_hashid(params[:referral_program_id]) if params[:referral_program_id].present?
    login = user.logins.create(referral_program:)

    cookies.signed["browser_token_#{login.hashid}"] = { value: login.browser_token, expires: Login::EXPIRATION.from_now }

    has_webauthn_enabled = user&.webauthn_credentials&.any?
    login_preference = session[:login_preference]

    if login_preference == "totp"
      redirect_to totp_login_path(login, return_to: params[:return_to]), status: :temporary_redirect
    elsif !has_webauthn_enabled || login_preference == "email" || login_preference == "sms"
      redirect_to login_code_login_path(login, return_to: params[:return_to]), status: :temporary_redirect
    else
      session[:auth_email] = login.user.email
      redirect_to choose_login_preference_login_path(login, return_to: params[:return_to])
    end
  rescue => e
    flash[:error] = e.message
    return redirect_to auth_users_path
  end

  # get page to choose preference
  def choose_login_preference
    return redirect_to auth_users_path if @email.nil?

    session.delete :login_preference
  end

  # post to set preference
  def set_login_preference
    remember = params[:remember] == "1"

    case params[:login_preference]
    when "email"
      session[:login_preference] = "email" if remember
      redirect_to login_code_login_path(@login), status: :temporary_redirect
    when "sms"
      session[:login_preference] = "sms" if remember
      redirect_to login_code_login_path(@login), status: :temporary_redirect
    when "totp"
      session[:login_preference] = "totp" if remember
      redirect_to totp_login_path(@login), status: :temporary_redirect
    when "webauthn"
      # This should never happen, because WebAuthn auth is handled on the frontend
      redirect_to choose_login_preference_login_path(@login)
    end
  end

  # post to request login code
  def login_code
    initialize_sms_params

    resp = LoginCodeService::Request.new(email: @email, sms: @use_sms_auth, ip_address: request.remote_ip, user_agent: request.user_agent).run

    @use_sms_auth = resp[:method] == :sms

    if resp[:error].present?
      flash[:error] = resp[:error]
      return redirect_to auth_users_path
    end

    render status: :unprocessable_entity

  rescue ActionController::ParameterMissing
    flash[:error] = "Please enter an email address."
    redirect_to auth_users_path
  end

  # get to see totp page
  def totp
    render status: :unprocessable_entity
  rescue ActionController::ParameterMissing
    flash[:error] = "Please enter an email address."
    redirect_to auth_users_path
  end

  def complete

    case params[:method]
    when "webauthn"
      webauthn_credential = WebAuthn::Credential.from_get(JSON.parse(params[:credential]))
      stored_credential = @user.webauthn_credentials.find_by!(webauthn_id: webauthn_credential.id)

      webauthn_credential.verify(
        session[:webauthn_challenge],
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count
      )

      stored_credential.update!(sign_count: webauthn_credential.sign_count)

      session[:login_preference] = "webauthn" if params[:remember] == "true"

      @login.update(authenticated_with_webauthn: true)

    when "login_code"
      UserService::ExchangeLoginCodeForUser.new(
        user_id: @login.user.id,
        login_code: params[:login_code],
        sms: params[:sms],
      ).run

      if params[:sms]
        @login.update(authenticated_with_sms: true)
      else
        @login.update(authenticated_with_email: true)
      end
    when "totp"
      if @user.totp&.verify(params[:code], drift_behind: 15, after: @user.totp&.last_used_at)
        @user.totp.update!(last_used_at: DateTime.now)
        @login.update(authenticated_with_totp: true)
      else
        return redirect_to totp_login_path(@login), flash: { error: "Invalid TOTP code, please try again." }
      end
    end

    # Clear the flash - this prevents the error message showing up after an unsuccessful -> successful login
    flash.clear

    # Only create a user session if authentication factors are met AND this login
    # has not created a user session before
    if @login.complete? && @login.user_session.nil?
      @login.update(user_session: sign_in(user: @login.user, fingerprint_info:))
      if @referral_program.present?
        redirect_to program_path(@referral_program)
      elsif @user.full_name.blank? || @user.phone_number.blank?
        redirect_to edit_user_path(@user.slug, return_to: params[:return_to])
      else
        redirect_to(params[:return_to] || root_path)
      end
    else
      set_available_methods

      if @sms_available || @email_available
        redirect_to login_code_login_path(@login), status: :temporary_redirect
      elsif @totp_available
        redirect_to totp_login_path(@login), status: :temporary_redirect
      else
        redirect_to choose_login_preference_login_path(@login, return_to: @return_to), status: :temporary_redirect
      end
    end
  rescue Errors::InvalidLoginCode => e
    flash.now[:error] = "Invalid login code!"
    initialize_sms_params
    return render :login_code, status: :unprocessable_entity
  rescue WebAuthn::SignCountVerificationError, WebAuthn::Error => e
    redirect_to auth_users_path, flash: { error: "Something went wrong." }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to auth_users_path, flash: { error: e.record.errors&.full_messages&.join(". ") }
  end

  private

  def set_login
    begin
      if params[:id]
        @login = Login.incomplete.active.find_by_hashid!(params[:id])
        @referral_program = @login.referral_program
        unless valid_browser_token?
          # error! browser token doesn't match the cookie.
          flash[:error] = "This doesn't seem to be the browser who began this login; please ensure cookies are enabled."
          redirect_to auth_users_path
        end
      elsif session[:auth_email]
        @login = User.find_by_email(session[:auth_email]).logins.create
        cookies.signed["browser_token_#{@login.hashid}"] = { value: @login.browser_token, expires: Login::EXPIRATION.from_now }
      else
        flash[:error] = "Please try again."
        redirect_to auth_users_path
      end
    rescue ActiveRecord::RecordNotFound
      flash[:error] = "Please start again."
      redirect_to auth_users_path, flash: { error: "Please start again." }
    end
  end

  def set_user
    @user = @login.user
    @email = @login.user.email
  end

  def set_available_methods
    @email_available = !@login.authenticated_with_email
    @sms_available = @user&.phone_number_verified && !@login.authenticated_with_sms
    @webauthn_available = @user&.webauthn_credentials&.any? && !@login.authenticated_with_webauthn
    @totp_available = @user&.totp.present? && !@login.authenticated_with_totp
  end

  def set_return_to
    @return_to = params[:return_to]
  end

  def fingerprint_info
    {
      fingerprint: params[:fingerprint],
      device_info: params[:device_info],
      os_info: params[:os_info],
      timezone: params[:timezone],
      ip: request.remote_ip
    }
  end

  def initialize_sms_params
    return if @login.authenticated_with_sms
    return if session[:login_preference] == "email" && !@login.authenticated_with_email

    if @login.user&.use_sms_auth || (@login.user&.phone_number_verified && (@login.authenticated_with_email || session[:login_preference] == "sms"))
      @use_sms_auth = true
      @phone_last_four = @login.user.phone_number.last(4)
    end
  end

  def valid_browser_token?
    return true if Rails.env.test?
    return true unless @login.browser_token
    return false unless cookies.signed["browser_token_#{@login.hashid}"]

    ActiveSupport::SecurityUtils.secure_compare(@login.browser_token, cookies.signed["browser_token_#{@login.hashid}"])
  end

end
