module Rack
  class Attack
    # If the app is behind a load balancer, `ip` will return the IP of the
    # load balancer instead of the actual IP the request came from, and since
    # all requests will seem to come from the same IP, throttling will be
    # triggered right away. To make sure we have the correct IP, we use
    # ActionDispatch#remote_ip, which determines the correct IP more thoroughly
    # than Rack.
    class Request < ::Rack::Request
      def remote_ip
        @remote_ip ||= (env['action_dispatch.remote_ip'] || ip).to_s
      end

      # This is needed because Ahoy (the gem our Analytics class calls) expects
      # the request to respond to `headers`, which Rack::Attack does not define.
      def headers
        {}
      end
    end

    ### Configure Cache ###

    # Note: The store is only used for throttling and fail2ban filtering;
    # not blocklisting & safelisting
    Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
      namespace: 'rack-attack',
      url: IdentityConfig.store.redis_throttle_url,
      expires_in: 2.weeks.to_i,
    )

    ### Configure Safelisting ###

    # Always allow requests from localhost
    # (blocklist & throttles are skipped)
    unless Rails.env.production?
      safelist('allow from localhost') do |req|
        req.remote_ip == '127.0.0.1' || req.remote_ip == '::1'
      end
    end

    ### Throttle Spammy Clients ###

    # If any single client IP is making tons of requests, then they're
    # probably malicious or a poorly-configured scraper. Either way, they
    # don't deserve to hog all of the app server's CPU. Cut them off!
    #
    # Note: If you're serving assets through rack, those requests may be
    # counted by rack-attack and this throttle may be activated too
    # quickly. If so, enable the condition to exclude them from tracking.

    # Throttle all requests by IP
    #
    # Key: "rack::attack:#{Time.now.to_i/:period}:req/ip:#{req.remote_ip}"
    if IdentityConfig.store.requests_per_ip_track_only_mode
      track(
        'req/ip',
        limit: IdentityConfig.store.requests_per_ip_limit,
        period: IdentityConfig.store.requests_per_ip_period,
      ) do |req|
        req.remote_ip unless req.path.starts_with?('/assets') || req.path.starts_with?('/packs')
      end
    else
      throttle(
        'req/ip',
        limit: IdentityConfig.store.requests_per_ip_limit,
        period: IdentityConfig.store.requests_per_ip_period,
      ) do |req|
        req.remote_ip unless req.path.starts_with?('/assets') || req.path.starts_with?('/packs')
      end
    end

    ### Prevent Brute-Force Login Attacks ###

    # The most common brute-force login attack is a brute-force password
    # attack where an attacker simply tries a large number of emails and
    # passwords to see if any credentials match.
    #
    # Another common method of attack is to use a swarm of computers with
    # different IPs to try brute-forcing a password for a specific account.

    # Throttle sign in attempts by IP address
    #
    # Key: "rack::attack:#{Time.now.to_i/:period}:logins/ip:#{req.remote_ip}"
    if IdentityConfig.store.logins_per_ip_track_only_mode
      track(
        'logins/ip',
        limit: IdentityConfig.store.logins_per_ip_limit,
        period: IdentityConfig.store.logins_per_ip_period,
      ) do |req|
        req.remote_ip if req.path == '/' && req.post?
      end
    else
      throttle(
        'logins/ip',
        limit: IdentityConfig.store.logins_per_ip_limit,
        period: IdentityConfig.store.logins_per_ip_period,
      ) do |req|
        req.remote_ip if req.path == '/' && req.post?
      end
    end

    ### Prevent SMS and voice spam ###

    # A user can use the `/otp/send` path to spam phone numbers with SMSs and
    # voice calls.

    # Throttle SMS and voice transactions by IP address
    #
    # Key: "rack::attack:#{Time.now.to_i/:period}:otps/ip:#{req.remote_ip}"
    if IdentityConfig.store.otps_per_ip_track_only_mode
      track(
        'otps/ip',
        limit: IdentityConfig.store.otps_per_ip_limit,
        period: IdentityConfig.store.otps_per_ip_period,
      ) do |req|
        req.remote_ip if req.path.match?(%r{/otp/send})
      end
    else
      throttle(
        'otps/ip',
        limit: IdentityConfig.store.otps_per_ip_limit,
        period: IdentityConfig.store.otps_per_ip_period,
      ) do |req|
        req.remote_ip if req.path.match?(%r{/otp/send})
      end
    end

    ### Prevent SMS and voice classification spam ###

    # A user can use the form at `/add/phone` and `/phone_setup` to check whether
    # a phone number is a VOIP number. We rate limit these endpoints to reduce
    # misuse of that form and charges from our phone classification vendor.

    # Throttle new phone addition
    #
    # Key: "rack::attack:#{Time.now.to_i/:period}:phone_setups/ip:#{req.remote_ip}"
    if IdentityConfig.store.phone_setups_per_ip_track_only_mode
      track(
        'phone_setups/ip',
        limit: IdentityConfig.store.phone_setups_per_ip_limit,
        period: IdentityConfig.store.phone_setups_per_ip_period,
      ) do |req|
        req.remote_ip if req.path.match?(%r{(/add/phone|/phone_setup)}) && !req.get?
      end
    else
      throttle(
        'phone_setups/ip',
        limit: IdentityConfig.store.phone_setups_per_ip_limit,
        period: IdentityConfig.store.phone_setups_per_ip_period,
      ) do |req|
        req.remote_ip if req.path.match?(%r{/add/phone|/phone_setup}) && !req.get?
      end
    end

    # Lockout IP addresses that are attempting to sign in with the same username
    # over and over.
    # After maxretry requests in findtime minutes, block all requests from that IP for bantime.
    blocklist('logins/email+ip') do |req|
      if req.path == '/' && req.post?
        # `filter` returns false if POST request is for the login page (but still
        # increments the count), so requests below the limit are not blocked until
        # they hit the limit. At that point, `filter` will return true and block.
        user = req.params.fetch('user', {})
        email_fingerprint = nil
        if user.is_a?(Hash)
          email = user['email'].to_s.downcase.strip
          email_fingerprint = Pii::Fingerprinter.fingerprint(email) if email.present?
        end
        email_and_ip = "#{email_fingerprint}-#{req.remote_ip}"
        maxretry = IdentityConfig.store.logins_per_email_and_ip_limit
        findtime = IdentityConfig.store.logins_per_email_and_ip_period
        bantime = IdentityConfig.store.logins_per_email_and_ip_bantime

        Allow2Ban.filter(email_and_ip, maxretry: maxretry, findtime: findtime, bantime: bantime) do
          # The count for the email and IP combination is incremented if the return value is truthy.
          req.path == '/' && req.post?
        end
      end
    end

    ### Custom Throttle Response ###

    # By default, Rack::Attack returns an HTTP 429 for throttled responses,
    # which is just fine.
    #
    # If you want to return 503 so that the attacker might be fooled into
    # believing that they've successfully broken your app (or you just want to
    # customize the response), then uncomment these lines.
    self.throttled_response = lambda do |_env|
      [
        429, # status
        { 'Content-Type' => 'text/html' }, # headers
        [::File.read('public/429.html')], # body
      ]
    end

    self.blocklisted_response = throttled_response
  end
end

ActiveSupport::Notifications.subscribe(
  'rack.attack',
) do |_name, _start, _finish, _request_id, payload|
  req = payload[:request]
  user = req.env['warden'].user || AnonymousUser.new
  analytics = Analytics.new(user: user, request: req, session: {}, sp: nil)
  analytics.track_event(Analytics::RATE_LIMIT_TRIGGERED, type: req.env['rack.attack.matched'])
end
