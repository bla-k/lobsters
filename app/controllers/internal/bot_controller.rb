# typed: false

#
# Internal endpoint used by the hackt-news-bot Telegram bridge to submit
# stories on behalf of authorised users.
#
# This is the "branch v2.1" controller: hackt.news runs in a container
# behind a Cloudflare Tunnel. We can't trust request.remote_ip for a
# loopback check anymore, so authentication is layered as follows:
#
#   1. Cloudflare Access gates the public hostname (e.g. bot.hackt.news)
#      with a self-hosted application + Service Token policy. CF refuses
#      requests without valid CF-Access-Client-Id/Secret BEFORE they
#      reach Puma.
#   2. CF injects a signed JWT in Cf-Access-Jwt-Assertion. This
#      controller verifies that JWT against CF's JWKS using the team
#      domain and the application audience tag (env vars below). If
#      the JWT is missing or invalid the request is rejected.
#   3. The body is HMAC-signed by the bot. We still verify HMAC as the
#      innermost layer of defence so an internal compromise of CF
#      doesn't let attackers freely impersonate users.
#
# Required env vars:
#   HACKT_BOT_SECRET              shared HMAC secret with the bot
#   CF_ACCESS_TEAM_DOMAIN         e.g. "yourteam.cloudflareaccess.com"
#   CF_ACCESS_AUD                 the audience tag of the CF Access app
#
# Add `gem "jwt", "~> 2.7"` to the hackt.news Gemfile before deploying
# this controller. JWT is a small, well-known gem that ships only what
# we need to verify signed tokens.

require "jwt"
require "net/http"

module Internal
  class BotController < ApplicationController
    # We talk to an external trusted process; no Rails session, no CSRF.
    skip_before_action :verify_authenticity_token, raise: false
    skip_forgery_protection if respond_to?(:skip_forgery_protection)

    before_action :verify_cf_access!
    before_action :verify_signature!

    # Window in seconds a signed request stays valid.
    REPLAY_WINDOW = 30

    # JWKS cache. Process-local; expires after 5 min so a key rotation
    # on the CF side propagates without a Puma restart.
    @@jwks_cache = nil
    @@jwks_fetched = Time.zone.at(0)
    JWKS_TTL_SEC = 300

    # GET /internal/bot/health
    def health
      render json: {ok: true, time: Time.current.to_i}
    end

    # GET /internal/bot/tags
    def tags
      list = Tag.active.order(:tag).map do |t|
        {
          tag: t.tag,
          description: t.description.to_s,
          is_media: !!t.is_media,
          privileged: !!t.privileged,
          permit_by_new_users: t.respond_to?(:permit_by_new_users) ? !!t.permit_by_new_users : true,
          category: (t.respond_to?(:category) && t.category) ? t.category.category : nil
        }
      end
      render json: {tags: list}
    end

    # GET /internal/bot/user_exists?username=foo
    def user_exists
      u = User.find_by(username: params[:username].to_s)
      if u.nil?
        render json: {exists: false} and return
      end
      render json: {
        exists: true,
        username: u.username,
        can_submit: u.can_submit_stories?,
        is_banned: u.is_banned?,
        is_new: u.is_new?
      }
    end

    # POST /internal/bot/submit
    def submit
      payload = parsed_body

      user = User.find_by(username: payload["username"].to_s)
      return render_error(:user_not_found, "no such hackt.news user", 404) if user.nil?
      return render_error(:user_banned, "user is banned", 403) if user.is_banned?
      unless user.can_submit_stories?
        return render_error(:user_cannot_submit, "user cannot submit stories", 403)
      end

      url = payload["url"].to_s.strip
      title = payload["title"].to_s.strip
      desc = payload["description"].to_s
      tnames = Array(payload["tags"]).map { |t| t.to_s.strip }.reject(&:empty?).uniq
      uia = !!payload["user_is_author"]
      uif = !!payload["user_is_following"]

      if url.blank? && desc.blank?
        return render_error(:bad_input, "either url or description is required", 422)
      end

      tag_records = Tag.active.where(tag: tnames).to_a
      missing = tnames - tag_records.map(&:tag)
      if missing.any?
        return render_error(:bad_input, "unknown or inactive tags: #{missing.join(", ")}", 422)
      end
      if tag_records.reject(&:is_media?).empty?
        return render_error(:bad_input, "at least one non-media tag is required", 422)
      end

      story = Story.new(user: user)
      story.fetching_ip = "127.0.0.1"
      story.title = title
      story.url = url if url.present?
      story.description = desc
      story.user_is_author = uia
      story.user_is_following = uif
      story.tags_was = []
      story.tags = tag_records

      saved = false
      Story.transaction do
        if story.valid? && !story.already_posted_recently?
          if story.save
            saved = true
          else
            raise ActiveRecord::Rollback
          end
        end
      end

      unless saved
        return render_error(
          :validation_failed,
          story.errors.full_messages.join("; ").presence ||
            "story rejected (likely duplicate / banned domain / new user restriction)",
          422,
          errors: story.errors.as_json
        )
      end

      begin
        if defined?(SendWebmentionJob) && !Rails.env.development?
          SendWebmentionJob.set(wait: 5.minutes).perform_later(story)
        end
        if defined?(CreateStoryCardJob)
          CreateStoryCardJob.perform_later(story)
        end
      rescue => e
        Rails.logger.warn("[bot] post-create job enqueue failed: #{e.class}: #{e.message}")
      end

      render json: {
        ok: true,
        short_id: story.short_id,
        url: Routes.title_url(story),
        title: story.title,
        tags: story.tags.map(&:tag).sort,
        submitted_at: story.created_at.to_i
      }
    end

    private

    def parsed_body
      @parsed_body ||= begin
        raw = request.raw_post
        raw.present? ? JSON.parse(raw) : {}
      rescue JSON::ParserError
        {}
      end
    end

    def render_error(code, message, status, extra = {})
      render(json: {ok: false, error: code.to_s, message: message}.merge(extra), status: status)
    end

    # -----------------------------------------------------------------
    # Cloudflare Access JWT validation
    # -----------------------------------------------------------------

    def verify_cf_access!
      team_domain = ENV["CF_ACCESS_TEAM_DOMAIN"].to_s
      aud = ENV["CF_ACCESS_AUD"].to_s
      if team_domain.empty? || aud.empty?
        Rails.logger.error("[bot] CF_ACCESS_TEAM_DOMAIN or CF_ACCESS_AUD not set; refusing request")
        return render(json: {ok: false, error: "server_misconfigured"}, status: 500)
      end

      jwt = request.headers["Cf-Access-Jwt-Assertion"].to_s
      if jwt.empty?
        return render(json: {ok: false, error: "missing_cf_access_jwt"}, status: 401)
      end

      begin
        jwks = fetch_jwks(team_domain)
        # JWT.decode with jwks: validates kid + signature in one shot.
        payload, _header = JWT.decode(
          jwt,
          nil,
          true,
          {
            algorithms: ["RS256"],
            jwks: {keys: jwks},
            iss: "https://#{team_domain}",
            verify_iss: true,
            aud: aud,
            verify_aud: true
          }
        )
        # JWT.decode already enforces exp / iat / nbf by default.
        @cf_access_email = payload["email"]
        @cf_access_common = payload["common_name"]  # set on Service Tokens
        @cf_access_sub = payload["sub"]
      rescue JWT::ExpiredSignature
        render(json: {ok: false, error: "cf_access_jwt_expired"}, status: 401)
      rescue JWT::InvalidAudError
        render(json: {ok: false, error: "cf_access_jwt_bad_aud"}, status: 401)
      rescue JWT::InvalidIssuerError
        render(json: {ok: false, error: "cf_access_jwt_bad_iss"}, status: 401)
      rescue JWT::DecodeError => e
        Rails.logger.warn("[bot] cf access jwt decode failed: #{e.message}")
        render(json: {ok: false, error: "cf_access_jwt_invalid"}, status: 401)
      rescue => e
        Rails.logger.error("[bot] cf access verification crashed: #{e.class}: #{e.message}")
        render(json: {ok: false, error: "cf_access_verification_failed"}, status: 500)
      end
    end

    # fetch_jwks returns the current set of JWK entries for the team. The
    # result is cached in-process for JWKS_TTL_SEC seconds.
    def fetch_jwks(team_domain)
      if @@jwks_cache && Time.current - @@jwks_fetched < JWKS_TTL_SEC
        return @@jwks_cache
      end

      uri = URI("https://#{team_domain}/cdn-cgi/access/certs")
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 3) do |http|
        res = http.get(uri.request_uri)
        unless res.is_a?(Net::HTTPSuccess)
          raise "JWKS fetch failed: HTTP #{res.code}"
        end
        @@jwks_cache = JSON.parse(res.body)["keys"]
        @@jwks_fetched = Time.current
      end
      @@jwks_cache
    end

    # -----------------------------------------------------------------
    # Body HMAC validation (unchanged from v2)
    # -----------------------------------------------------------------

    def verify_signature!
      secret = ENV["HACKT_BOT_SECRET"].to_s
      if secret.empty?
        Rails.logger.error("[bot] HACKT_BOT_SECRET is not set; refusing request")
        return render(json: {ok: false, error: "server_misconfigured"}, status: 500)
      end

      ts = request.headers["X-Bot-Timestamp"].to_s
      sig = request.headers["X-Bot-Signature"].to_s
      if ts.empty? || sig.empty?
        return render(json: {ok: false, error: "missing_auth_headers"}, status: 401)
      end

      ts_i = ts.to_i
      if ts_i <= 0 || (Time.current.to_i - ts_i).abs > REPLAY_WINDOW
        return render(json: {ok: false, error: "stale_timestamp"}, status: 401)
      end

      body = request.raw_post.to_s
      mac = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}")

      unless ActiveSupport::SecurityUtils.secure_compare(mac, sig)
        render(json: {ok: false, error: "bad_signature"}, status: 401)
      end
    end
  end
end
