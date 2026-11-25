# frozen_string_literal: true

require "openssl"

module SnappedCut
  # How far a signature's timestamp may be from now before it is refused.
  WEBHOOK_TOLERANCE_MS = 300_000

  # Checks an X-Snappedcut-Signature header (+t=<epoch ms>,v1=<hex>+) against
  # the raw request body. Pass the body exactly as received, not re-serialised.
  def self.verify_webhook(secret, raw_body, header, now_ms = (Time.now.to_f * 1000).to_i)
    parts = header.to_s.split(",").to_h { |part| part.split("=", 2).then { |k, v| [k, v.to_s] } }
    t = parts["t"].to_s
    v1 = parts["v1"].to_s
    return false unless t.match?(/\A\d+\z/)
    return false if (now_ms - t.to_i).abs > WEBHOOK_TOLERANCE_MS
    return false unless v1.match?(/\A[0-9a-f]{64}\z/)

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{t}.#{raw_body}")
    OpenSSL.fixed_length_secure_compare(expected, v1)
  end
end
