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

    attr_reader :base

    # @param chunk_size [Integer] lower it if the process is memory-constrained;
    #   one chunk is held in memory while it is sent.
    def initialize(key: nil, base: DEFAULT_BASE, timeout: 120, chunk_size: CHUNK, http: nil)
      @key = key || ENV.fetch("SNAPCUT_KEY", "")
      @base = base.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @chunk_size = chunk_size
      @http = http
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

    # The rendered file. Raises unless the job is done.
    def output(id)
      request(Net::HTTP::Get, "/api/jobs/#{escape(id)}/output").body.to_s
    end

    # Wait for a job to finish, then hand back the file.
    #
    # Polls with a backoff rather than at a fixed interval: a render is minutes,
    # so a one-second poll spends most of its requests learning nothing, and the
    # server has a rate limit a busy loop will find.
    #
    # @yield [Job] every poll result, if a block is given
    def wait(id, timeout: 1800, sleeper: nil)
      sleeper ||= ->(seconds) { sleep(seconds) }
      deadline = monotonic + timeout
      delay = 1.0

      loop do
        current = job(id)
        yield current if block_given?

        return output(id) if current.done?
        # The credits are already back -- the server refunds a failure -- so this
        # is a plain error, not something the caller has to reconcile.
        raise Error.new(current.error || "The render failed.", 500) if current.failed?

        raise Error.new("Job #{id} is still #{current.state}.", 504) if monotonic > deadline

        sleeper.call(delay)
        delay = [delay * 1.5, 15.0].min
      end
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def escape(value)
      URI.encode_www_form_component(value.to_s)
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

    def request(verb, path, body = nil, content_type = nil)
      uri = URI.parse("#{@base}#{path}")
      req = verb.new(uri)
      req["user-agent"] = "snappedcut-ruby/#{VERSION}"
      req["authorization"] = "Bearer #{@key}" unless @key.empty?
      req["content-type"] = content_type if content_type
      req.body = body if body

      response = perform(uri, req)
      return response if response.code.to_i < 400

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
        expected: detail["expected"].to_i
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
