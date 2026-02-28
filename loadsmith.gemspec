# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "loadsmith"
  spec.version = "0.1.0"
  spec.authors = ["loadsmith"]
  spec.summary = "Screen-based load testing framework for Ruby"
  spec.description = "A simple, screen-transition-based load testing framework with Ractor support"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["lib/**/*.rb", "bin/*"]
  spec.bindir = "bin"
  spec.require_paths = ["lib"]
end
