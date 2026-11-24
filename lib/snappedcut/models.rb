# frozen_string_literal: true

module SnappedCut
  # What the server decided the job was, and therefore what it cost.
  Priced = Struct.new(:seconds, :project, :layers, keyword_init: true) do
    def self.from(raw)
      raw ||= {}
      new(
        seconds: raw["seconds"].to_f,
        project: raw["project"].to_s,
        layers: raw["layers"].to_i
      )
    end
  end

  Job = Struct.new(:id, :kind, :state, :seconds, :error, :created_at, :updated_at,
                   keyword_init: true) do
    def self.from(raw)
      raw ||= {}
      new(
        id: raw["id"].to_s,
        kind: (raw["kind"] || "cloud-render").to_s,
        state: (raw["state"] || "queued").to_s,
        seconds: raw["seconds"].to_f,
        error: raw["error"]&.to_s,
        created_at: raw["createdAt"].to_i,
        updated_at: raw["updatedAt"].to_i
      )
    end

    def done?
      state == "done"
    end

    def failed?
      state == "failed"
    end
  end

  # A job plus what queueing it cost.
  QueuedJob = Struct.new(:job, :charged, :credits, :priced, keyword_init: true) do
    def self.from(body)
      body ||= {}
      new(
        job: Job.from(body["job"]),
        charged: body["charged"].to_i,
        credits: body["credits"].to_i,
        priced: Priced.from(body["priced"])
      )
    end

    def id
      job.id
    end
  end

  Account = Struct.new(:id, :email, :credits, :prices, keyword_init: true) do
    def self.from(raw)
      raw ||= {}
      new(
        id: raw["id"].to_s,
        email: raw["email"].to_s,
        credits: raw["credits"].to_i,
        prices: raw["prices"] || {}
      )
    end
  end
end
