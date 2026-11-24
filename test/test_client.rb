# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "snappedcut"

# Tests run on minitest, which ships with Ruby, so CI installs nothing to run them.
class TestClient < Minitest::Test
  QUEUED = {
    "job" => { "id" => "j1", "kind" => "cloud-render", "state" => "queued", "seconds" => 4 },
    "charged" => 8, "credits" => 92,
    "priced" => { "seconds" => 4, "project" => "p", "layers" => 2 }
  }.freeze

  def job_body(state, error = nil)
    { "id" => "j1", "kind" => "cloud-render", "state" => state,
      "error" => error, "seconds" => 4 }
  end

  # A fake Net::HTTP response, and a transport that answers from a script.
  Reply = Struct.new(:code, :body)

  def transport(*replies)
    @calls = []
    queue = replies.dup
    lambda do |uri, req|
      @calls << { url: uri.to_s, method: req.method, body: req.body,
                  headers: req.to_hash.transform_values(&:first) }
      flunk "unexpected request: #{uri}" if queue.empty?
      status, body = queue.shift
      Reply.new(status.to_s, body.is_a?(String) ? body : JSON.generate(body))
    end
  end

  def client(*replies, **options)
    SnappedCut::Client.new(key: "sk_snapcut_test", http: transport(*replies), **options)
  end

  def test_key_is_sent_as_a_bearer_token
    account = client([200, { "id" => "a", "email" => "e@x.com", "credits" => 50 }]).account

    assert_equal "e@x.com", account.email
    assert_equal "Bearer sk_snapcut_test", @calls[0][:headers]["authorization"]
    assert_equal "https://snappedcut.com/api/account", @calls[0][:url]
  end

  def test_key_falls_back_to_the_environment
    ENV["SNAPCUT_KEY"] = "sk_snapcut_env"
    SnappedCut::Client.new(http: transport([200, {}])).account
    assert_equal "Bearer sk_snapcut_env", @calls[0][:headers]["authorization"]
  ensure
    ENV.delete("SNAPCUT_KEY")
  end

  def test_inspect_never_contains_the_key
    # An inspect ends up in logs and exception reports.
    refute_includes SnappedCut::Client.new(key: "sk_snapcut_secret").inspect, "sk_snapcut_secret"
  end

  def test_a_trailing_slash_on_the_base_does_not_double_up
    client([200, {}], base: "http://localhost:3000/").account
    assert_equal "http://localhost:3000/api/account", @calls[0][:url]
  end

  def test_a_402_is_rescuable_without_parsing_a_message
    error = assert_raises(SnappedCut::Error) do
      client([402, { "error" => "Not enough credits." }]).account
    end
    assert error.out_of_credits?
    assert_equal 402, error.status
  end

  def test_a_429_reports_itself_as_rate_limited
    error = assert_raises(SnappedCut::Error) do
      client([429, { "error" => "Slow down.", "retryAfterMs" => 2000 }]).account
    end
    assert error.rate_limited?
    assert_equal 2000, error.retry_after_ms
  end

  def test_a_non_json_error_body_still_raises_cleanly
    error = assert_raises(SnappedCut::Error) { client([500, "<html>oops"]).account }
    assert_equal 500, error.status
  end

  def test_render_never_sends_a_duration
    queued = client([200, QUEUED]).render("zipbytes")

    assert_equal 8, queued.charged
    assert_equal 4.0, queued.priced.seconds
    # A caller-supplied duration would be a caller-supplied price.
    refute_includes @calls[0][:url], "seconds"
  end

  def test_a_small_bundle_is_one_request
    client([200, QUEUED]).render("x" * 1024)
    assert_equal 1, @calls.length
    refute_includes @calls[0][:url], "offset"
  end

  def test_a_large_bundle_is_chunked_and_the_last_chunk_is_final
    client([200, { "upload" => "u1", "received" => 1024 }], [200, QUEUED], chunk_size: 1024)
      .render("\0" * 1040)

    assert_equal 2, @calls.length
    assert_includes @calls[0][:url], "offset=0"
    assert_includes @calls[1][:url], "upload=u1"
    assert_includes @calls[1][:url], "final=1"
  end

  def test_a_409_resumes_from_the_offset_the_server_reports
    # Our count and the server's disagreed. The server has the file.
    client([200, { "upload" => "u1", "received" => 10 }],
           [409, { "error" => "offset", "expected" => 1024 }],
           [200, QUEUED], chunk_size: 1024).render("\0" * 1040)

    assert_includes @calls[2][:url], "offset=1024"
  end

  def test_a_refusal_mid_upload_stops_rather_than_retrying
    error = assert_raises(SnappedCut::Error) do
      client([200, { "upload" => "u1", "received" => 10 }],
             [402, { "error" => "Not enough credits." }], chunk_size: 1024).render("\0" * 1040)
    end
    assert error.out_of_credits?
    assert_equal 2, @calls.length
  end

  def test_an_io_is_chunked_without_holding_the_whole_file
    # The point of the IO path: one chunk in memory, not the whole file.
    io = StringIO.new("\0" * 2048)
    queued = client([200, { "upload" => "u1", "received" => 1024 }], [200, QUEUED],
                    chunk_size: 1024).render(io)

    assert_equal "j1", queued.id
    assert_equal 2, @calls.length
    assert_equal 1024, @calls[0][:body].bytesize
  end

  def test_a_bundle_of_the_wrong_type_fails_before_any_request
    assert_raises(SnappedCut::Error) { client.render(42) }
  end

  def test_wait_polls_until_done_then_returns_the_bytes
    seen = []
    file = client([200, job_body("running")], [200, job_body("done")], [200, "MOVIE"])
           .wait("j1", sleeper: ->(_) {}) { |job| seen << job.state }

    assert_equal %w[running done], seen
    assert_equal "MOVIE", file
  end

  def test_a_failed_job_raises_rather_than_returning_an_empty_file
    error = assert_raises(SnappedCut::Error) do
      client([200, job_body("failed", "decode failed")]).wait("j1", sleeper: ->(_) {})
    end
    assert_includes error.message, "decode failed"
  end

  def test_wait_gives_up_at_the_timeout_with_a_504
    replies = Array.new(20) { [200, job_body("queued")] }
    error = assert_raises(SnappedCut::Error) do
      client(*replies).wait("j1", timeout: -1, sleeper: ->(_) {})
    end
    assert_equal 504, error.status
  end

  def test_a_job_id_is_escaped_into_the_path
    client([200, job_body("done")]).job("a/../b")
    assert_includes @calls[0][:url], "a%2F..%2Fb"
  end

  def test_jobs_unwraps_the_envelope
    found = client([200, { "jobs" => [job_body("done"), job_body("queued")] }]).jobs
    assert_equal %w[done queued], found.map(&:state)
  end

  def test_jobs_tolerates_an_empty_account
    assert_empty client([200, {}]).jobs
  end
end
