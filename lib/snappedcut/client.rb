# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module SnappedCut
  # A client for the Snapped Cut cloud render API.
  #
  # The standard library and nothing else -- no gems -- so it drops into a Rails
  # app or a bare script without touching the bundle. The API is five endpoints;
  # a client for it should be readable in one sitting.
  #
  #   snapcut = SnappedCut::Client.new           # reads SNAPCUT_KEY
  #   job = snapcut.render(File.open("project.zip", "rb"))
  #   File.binwrite("out.webm", snapcut.wait(job.id))
  #
  # This covers the server API: the cloud render queue and the account behind it.
  # Everything else Snapped Cut does happens in a browser on WebCodecs, and no
  # SDK can make Ruby do that.
  class Client
    DEFAULT_BASE = "https://snappedcut.com"

    # How much of a bundle goes in one request.
    #
    # Cloudflare's free plan refuses a proxied request body over 100 MB and the
    # site is behind it, so a 512 MB bundle cannot be one POST however well it
    # streams. 64 MiB leaves room for headers and for a tighter cap on some
    # other proxy without making the chunk count silly.
    CHUNK = 64 * 1024 * 1024

    MAX_ATTEMPTS = 3

    attr_reader :base, :webhooks, :destinations

    # @param chunk_size [Integer] lower it if the process is memory-constrained;
    #   one chunk is held in memory while it is sent.
    def initialize(key: nil, base: DEFAULT_BASE, timeout: 120, chunk_size: CHUNK, http: nil)
      @key = key || ENV.fetch("SNAPCUT_KEY", "")
      @base = base.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @chunk_size = chunk_size
      @http = http
      @webhooks = Webhooks.new(self)
      @destinations = Destinations.new(self)
    end

    # Also available as SnappedCut.verify_webhook.
    def self.verify_webhook(...)
      SnappedCut.verify_webhook(...)
    end

    # Never the key: an inspect ends up in logs and exception reports.
    def inspect
      "#<SnappedCut::Client base=#{@base.inspect} key=#{@key.empty? ? "unset" : "set"}>"
    end

    # The account behind the key: who, and how many credits are left.
    def account
      Account.from(get_json("/api/account"))
    end

    # Queue a render.
    #
    # There is no +seconds+ argument and there should not be: the server reads
    # the timeline duration out of the bundle's own project.json and prices on
    # that. A duration supplied by the caller is a price supplied by the caller.
    # What it was charged for comes back in +priced+.
    #
    # +bundle+ is a String or any IO. Pass an IO for anything large: a String
    # holds the whole file in memory, an IO holds one chunk.
    def render(bundle, kind: "cloud-render")
      size = size_of(bundle)

      if size <= @chunk_size
        return QueuedJob.from(
          post_json("/api/jobs?#{encode(kind: kind)}", slice(bundle, 0, size))
        )
      end

      render_chunked(bundle, kind, size)
    end

    def job(id)
      Job.from(get_json("/api/jobs/#{escape(id)}"))
    end

    def jobs
      rows = get_json("/api/jobs")["jobs"] || []
      rows.map { |raw| Job.from(raw) }
    end

    # The rendered file. Raises unless the job is done. +index+ picks one of
    # several outputs; the query is only sent when it is not the first.
    def output(id, index = 0)
      query = index.positive? ? "?index=#{index.to_i}" : ""
      request(Net::HTTP::Get, "/api/jobs/#{escape(id)}/output#{query}").body.to_s
    end
    alias download_output output

    # Wait for a job to finish, then hand back the file.
    #
    # Polls with a backoff rather than at a fixed interval: a render is minutes,
    # so a one-second poll spends most of its requests learning nothing, and the
    # server has a rate limit a busy loop will find.
    #
    # @yield [Job] every poll result, if a block is given
    def wait(id, timeout: 1800, sleeper: nil)
      poll(id, timeout, sleeper) { |raw| yield Job.from(raw) if block_given? }
      output(id)
    end

    # --- JSON jobs ---------------------------------------------------------
    #
    # These return Hashes with string keys, exactly as the server sent them, so
    # a field added within a version never breaks anything.

    # POST /api/jobs as JSON. An idempotency key makes a retry return the first
    # job instead of charging for a second one.
    def create_job(request, idempotency_key = nil)
      key = idempotency_key || request[:idempotencyKey] || request["idempotencyKey"]
      call_json(Net::HTTP::Post, "/api/jobs", request, key ? { "idempotency-key" => key } : {})
    end

    # Up to 100 jobs; +defaults+ is merged under each by the server.
    def create_batch(jobs, defaults = nil)
      body = { jobs: jobs }
      body[:defaults] = defaults if defaults
      call_json(Net::HTTP::Post, "/api/jobs/batch", body)
    end

    def get_job(id)
      get_json("/api/jobs/#{escape(id)}")
    end

    def list_jobs
      get_json("/api/jobs")["jobs"] || []
    end

    # Polls until the job is done (returns its Hash) or failed (raises).
    # Backoff from 1 s, x1.5 each poll, capped at 15 s.
    def wait_for_job(id, timeout: 1800, sleeper: nil)
      poll(id, timeout, sleeper)
    end

    # --- Designs -----------------------------------------------------------

    def compile_design(design, vars = nil)
      body = { design: design }
      body[:vars] = vars if vars
      call_json(Net::HTTP::Post, "/api/designs", body)
    end

    def render_design(design, options = {}, idempotency_key = nil)
      create_job(options.merge(design: design), idempotency_key)
    end

    # --- Uploads -----------------------------------------------------------

    # Uploads a String or an IO (read one chunk at a time, never whole), then
    # confirms it and returns the asset.
    def upload(data, content_type, name = nil)
      body = { contentType: content_type }
      body[:name] = name if name
      made = call_json(Net::HTTP::Post, "/api/uploads", body)
      url = made.dig("upload", "url").to_s
      step = made.dig("upload", "maxChunkBytes").to_i
      raise Error.new("The upload has no chunk size.", 0) unless step.positive?

      size = size_of(data)
      offset = 0
      loop do
        to = [size, offset + step].min
        # The upload URL carries its own permission; the API key is not sent to it.
        request(Net::HTTP::Put, nil, slice(data, offset, to), content_type, url: "#{url}&offset=#{offset}")
        offset = to
        break if offset >= size
      end
      call_json(Net::HTTP::Post, "/api/uploads/#{escape(made["assetId"])}/confirm", {})["asset"]
    end

    def get_asset(id)
      get_json("/api/uploads/#{escape(id)}")["asset"]
    end

    def delete_asset(id)
      request(Net::HTTP::Delete, "/api/uploads/#{escape(id)}")
      nil
    end

    # --- Meta, usage, embed ------------------------------------------------

    # Every operation, the render parameters, and the presets.
    def operations
      get_json("/api/operations")
    end

    def usage(from: nil, to: nil, end_user_id: nil, group_by: nil)
      params = { from: from, to: to, endUserId: end_user_id, groupBy: group_by }.compact
      get_json(params.empty? ? "/api/usage" : "/api/usage?#{encode(**params)}")
    end

    # Deletes one end user's renders and uploads, and their id from everything kept.
    def delete_end_user(end_user_id)
      call_json(Net::HTTP::Delete, "/api/usage?#{encode(endUserId: end_user_id)}")
    end

    # Mints an embed session token for one of your end users. Server side only.
    def create_embed_token(publishable_key, end_user_id, max_credits: nil, ttl_seconds: nil, origin: nil, features: nil)
      body = { pk: publishable_key, endUserId: end_user_id, maxCredits: max_credits,
               ttlSeconds: ttl_seconds, origin: origin, features: features }.compact
      call_json(Net::HTTP::Post, "/api/embed/tokens", body)
    end

    # --- Plumbing the sub-resources share ----------------------------------

    # @api private
    # JSON in (when +body+ is given), JSON out. +allow+ lists statuses that are
    # answers rather than errors.
    def call_json(verb, path, body = nil, headers = {}, allow: [])
      raw = request(verb, path, body && JSON.generate(body), body && "application/json",
                    headers: headers, allow: allow).body.to_s
      raw.empty? ? {} : parse(raw)
    end

    # @api private
    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def poll(id, timeout, sleeper)
      sleeper ||= ->(seconds) { sleep(seconds) }
      deadline = monotonic + timeout
      delay = 1.0

      loop do
        current = get_job(id)
        yield current if block_given?

        return current if current["state"] == "done"
        # The credits are already back -- the server refunds a failure -- so this
        # is a plain error, not something the caller has to reconcile.
        raise Error.new(current["error"] || "The render failed.", 500) if current["state"] == "failed"

        raise Error.new("Job #{id} is still #{current["state"]}.", 504) if monotonic > deadline

        sleeper.call(delay)
        delay = [delay * 1.5, 15.0].min
      end
    end

    def encode(**params)
      URI.encode_www_form(params)
    end

    def size_of(bundle)
      return bundle.bytesize if bundle.is_a?(String)
      raise Error.new("A bundle is a String or an IO.", 0) unless bundle.respond_to?(:read)

      bundle.size
    end

    # One slice of the bundle. An IO is read rather than copied whole, which is
    # the difference between needing one chunk of memory and the entire file.
    def slice(bundle, from, to)
      return bundle.byteslice(from, to - from) if bundle.is_a?(String)

      bundle.seek(from)
      bundle.read(to - from) || ""
    end

    def render_chunked(bundle, kind, size)
      upload = ""
      offset = 0
      attempts = 0

      while offset < size
        to = [size, offset + @chunk_size].min
        last = to == size

        query = { kind: kind, offset: offset }
        query[:upload] = upload unless upload.empty?
        query[:final] = "1" if last

        begin
          body = post_json("/api/jobs?#{encode(**query)}", slice(bundle, offset, to))
          return QueuedJob.from(body) if last

          # The server's count, not ours: it is the one with the file.
          upload = body["upload"].to_s
          offset = body["received"].to_i
          attempts = 0
        rescue Error => e
          attempts += 1
          raise if attempts > MAX_ATTEMPTS

          # Where the server says its copy ends. Believe it over our own count.
          if e.status == 409
            offset = e.expected
            next
          end
          # A refusal is a refusal -- no credits, bad bundle, bad key. Only a
          # lost connection (0) or a server fault is worth sending again.
          raise if e.status != 0 && e.status < 500
        end
      end

      raise Error.new("That upload ended without queueing a job.", 0)
    end

    def get_json(path)
      parse(request(Net::HTTP::Get, path).body)
    end

    def post_json(path, body)
      parse(request(Net::HTTP::Post, path, body, "application/zip").body)
    end

    def parse(raw)
      parsed = JSON.parse(raw.to_s)
      raise Error.new("Snapped Cut sent something that is not an object.", 0) unless parsed.is_a?(Hash)

      parsed
    end

    # +url+ is an absolute URL that carries its own permission (an upload
    # URL), so the key is never sent to it.
    def request(verb, path, body = nil, content_type = nil, headers: {}, url: nil, allow: [])
      uri = URI.parse(url || "#{@base}#{path}")
      req = verb.new(uri)
      req["user-agent"] = "snappedcut-ruby/#{VERSION}"
      req["authorization"] = "Bearer #{@key}" unless @key.empty? || url
      req["content-type"] = content_type if content_type
      headers.each { |name, value| req[name] = value }
      req.body = body if body

      response = perform(uri, req)
      return response if response.code.to_i < 400 || allow.include?(response.code.to_i)

      # An error body is not guaranteed to be JSON -- a proxy may answer with
      # HTML -- and the status is the part that matters either way.
      detail = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError, TypeError
        {}
      end
      detail = {} unless detail.is_a?(Hash)

      raise Error.new(
        detail["error"] || "Snapped Cut said #{response.code}.",
        response.code.to_i,
        retry_after_ms: detail["retryAfterMs"].to_i,
        expected: detail["expected"].to_i,
        code: detail["code"]&.to_s
      )
    end

    def perform(uri, req)
      return @http.call(uri, req) if @http

      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == "https",
                      open_timeout: @timeout,
                      read_timeout: @timeout) { |http| http.request(req) }
    rescue StandardError => e
      # Never reached the server, so worth sending again.
      raise Error.new("Could not reach Snapped Cut: #{e.message}", 0)
    end
  end
end
