# frozen_string_literal: true

module SnappedCut
  # Webhook endpoints on the account: +client.webhooks+. Hashes in and out.
  class Webhooks
    def initialize(client)
      @client = client
    end

    def list
      @client.call_json(Net::HTTP::Get, "/api/webhooks")["webhooks"] || []
    end

    # Returns { "webhook" => ..., "secret" => ... }. The secret comes back this once.
    def create(url, events = nil)
      body = { url: url }
      body[:events] = events if events
      @client.call_json(Net::HTTP::Post, "/api/webhooks", body)
    end

    def get(id)
      @client.call_json(Net::HTTP::Get, path(id))["webhook"]
    end

    def update(id, url: nil, events: nil, enabled: nil)
      patch = { url: url, events: events, enabled: enabled }.compact
      @client.call_json(Net::HTTP::Patch, path(id), patch)["webhook"]
    end

    def delete(id)
      @client.call_json(Net::HTTP::Delete, path(id))
      nil
    end

    # The new secret. The old one stops verifying.
    def rotate(id)
      @client.call_json(Net::HTTP::Post, "#{path(id)}/rotate", {})["secret"]
    end

    def deliveries(id, limit = 50)
      @client.call_json(Net::HTTP::Get, "#{path(id)}/deliveries?limit=#{limit.to_i}")["deliveries"] || []
    end

    def test(id)
      @client.call_json(Net::HTTP::Post, "#{path(id)}/test", {})
    end

    private

    def path(id)
      "/api/webhooks/#{@client.escape(id)}"
    end
  end

  # Saved storage destinations: +client.destinations+. Hashes in and out.
  class Destinations
    def initialize(client)
      @client = client
    end

    def list
      @client.call_json(Net::HTTP::Get, "/api/destinations")["destinations"] || []
    end

    def create(input)
      @client.call_json(Net::HTTP::Post, "/api/destinations", input)["destination"]
    end

    def get(id)
      @client.call_json(Net::HTTP::Get, path(id))["destination"]
    end

    def update(id, patch)
      @client.call_json(Net::HTTP::Patch, path(id), patch)["destination"]
    end

    def delete(id)
      @client.call_json(Net::HTTP::Delete, path(id))
      nil
    end

    # A failed test write (422) is an answer, { "ok" => false, ... }, not an exception.
    def test(id)
      @client.call_json(Net::HTTP::Post, "#{path(id)}/test", {}, allow: [422])
    end

    def presign(id, key, expires_in = nil)
      body = { key: key }
      body[:expiresIn] = expires_in if expires_in
      @client.call_json(Net::HTTP::Post, "#{path(id)}/presign", body)
    end

    private

    def path(id)
      "/api/destinations/#{@client.escape(id)}"
    end
  end
end
