# frozen_string_literal: true

module SnappedCut
  # A refusal from the server, with its status.
  #
  # A distinct class because the two failures callers actually branch on --
  # "no credits" (402) and "slow down" (429) -- are not exceptional and should
  # be rescued without parsing a message. Status 0 means the server was never
  # reached, which is the one case worth sending again.
  class Error < StandardError
    attr_reader :status, :retry_after_ms, :expected

    # @param expected [Integer] on a 409 from a chunked upload, the byte the
    #   server's copy ends at.
    def initialize(message, status, retry_after_ms: 0, expected: 0)
      super(message)
      @status = status
      @retry_after_ms = retry_after_ms
      @expected = expected
    end

    def out_of_credits?
      status == 402
    end

    def rate_limited?
      status == 429
    end
  end
end
