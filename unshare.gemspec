# frozen_string_literal: true

require_relative "lib/unshare/version"

Gem::Specification.new do |spec|
  spec.name = "unshare"
  spec.version = Unshare::VERSION
  spec.authors = ["Shannon Skipper"]
  spec.email = ["shannonskipper@gmail.com"]
  spec.summary = "Thread-local working directories"
  spec.description = "Thread-local chdir for Linux and macOS, using Fiddle"
  spec.homepage = "https://github.com/havenwood/unshare"
  spec.required_ruby_version = ">= 4.0.0"
  spec.requirements = ["CRuby", "Linux or macOS"]
  spec.license = "MIT"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.add_dependency "fiddle"
  spec.files = Dir["lib/**/*.rb", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]
end
