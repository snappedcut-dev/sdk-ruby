# frozen_string_literal: true

require_relative "lib/snappedcut/version"

Gem::Specification.new do |spec|
  spec.name = "snappedcut"
  spec.version = SnappedCut::VERSION
  spec.authors = ["Illuminati Networks"]
  spec.summary = "Ruby SDK for the Snapped Cut cloud render API."
  spec.description = "A client for the Snapped Cut cloud render API. " \
                     "The standard library and nothing else -- no gem dependencies."
  spec.homepage = "https://snappedcut.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/snappedcut-dev/sdk-ruby",
    "bug_tracker_uri" => "https://github.com/snappedcut-dev/sdk-ruby/issues",
    "documentation_uri" => "https://snappedcut.com/docs",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb"] + ["README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
