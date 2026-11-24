# frozen_string_literal: true

require_relative "snappedcut/version"
require_relative "snappedcut/error"
require_relative "snappedcut/models"
require_relative "snappedcut/client"

# Snapped Cut: a video editor that runs in the browser, and a cloud render queue
# that does not. This gem talks to the queue.
module SnappedCut
  # Shorthand for SnappedCut::Client.new.
  def self.new(**options)
    Client.new(**options)
  end
end
