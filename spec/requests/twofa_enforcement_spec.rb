# typed: false

require "rails_helper"

describe "2FA enforcement for privileged users", type: :request do
  let(:password) { "asdf" }

  def sign_in_with_2fa(user, secret)
    post "/login", params: {email: user.email, password: password}
    totp = ROTP::TOTP.new(secret)
    post "/login/2fa_verify", params: {totp_code: totp.now}
  end

  context "regular user without 2FA" do
    let(:user) { create(:user, password: password) }

    it "is not redirected" do
      sign_in user
      get "/"
      expect(response).to be_successful
    end
  end

  context "moderator without 2FA" do
    let(:moderator) { create(:user, :moderator, password: password) }

    before { sign_in moderator }

    it "is redirected to /settings/2fa with a flash" do
      get "/"
      expect(response).to redirect_to("/settings/2fa")
      expect(flash[:error]).to include("Two-factor authentication is required")
    end

    it "can reach /settings/2fa" do
      get "/settings/2fa"
      expect(response).to be_successful
    end

    it "can reach the enrollment flow via twofa_auth" do
      post "/settings/2fa_auth", params: {user: {password: password}}
      expect(response).to redirect_to("/settings/2fa_enroll")
    end

    it "can log out" do
      post "/logout"
      expect(response).to redirect_to("/")
    end
  end

  context "admin without 2FA" do
    let(:admin) { create(:user, :admin, password: password) }

    it "is redirected to /settings/2fa" do
      sign_in admin
      get "/"
      expect(response).to redirect_to("/settings/2fa")
    end
  end

  context "moderator with 2FA enrolled" do
    let(:secret) { ROTP::Base32.random }
    let(:moderator) do
      user = create(:user, :moderator, password: password)
      user.update!(totp_secret: secret)
      user
    end

    it "is not redirected" do
      sign_in_with_2fa(moderator, secret)
      get "/"
      expect(response).to be_successful
    end
  end
end
