class SetupController < ActionController::Base
  before_action :verify_token!

  def show
  end

  def start
    email = params[:email].to_s.strip
    if email.blank?
      @error = "Please enter an email address."
      return render :show
    end

    authenticator = Gog::Authenticator.new(agent_principal: @principal)
    result = authenticator.start_auth(email)

    if result.success
      @auth_url = result.output
      @email = email
      render :auth_url
    else
      @error = result.error.presence || "Failed to start authentication."
      render :show
    end
  end

  def complete
    email = params[:email].to_s.strip
    auth_url = params[:auth_url].to_s.strip

    if auth_url.blank?
      @error = "Please paste the redirect URL."
      @auth_url = params[:original_auth_url]
      @email = email
      return render :auth_url
    end

    authenticator = Gog::Authenticator.new(agent_principal: @principal)
    result = authenticator.complete_auth(email, auth_url)

    if result.success
      render :success
    else
      @error = result.error.presence || "Authentication failed."
      @auth_url = params[:original_auth_url]
      @email = email
      render :auth_url
    end
  end

  private

  def verify_token!
    data = Gog::SetupToken.verify(params[:token])

    unless data
      render plain: "This setup link has expired or is invalid. Please request a new one from your agent.", status: :gone
      return
    end

    Current.workspace = Workspace.find_by(id: data[:workspace_id])
    @user = User.find_by(id: data[:user_id])
    @agent = Agent.find_by(id: data[:agent_id])
    @principal = AgentPrincipal.find_by(agent: @agent, user: @user)

    unless Current.workspace && @user && @agent && @principal
      render plain: "Setup configuration not found. Please request a new link from your agent.", status: :gone
    end
  end
end
