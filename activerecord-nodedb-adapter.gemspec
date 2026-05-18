require_relative "lib/activerecord_nodedb_adapter/version"

Gem::Specification.new do |spec|
  spec.name    = "activerecord-nodedb-adapter"
  spec.version = ActiveRecordNodedbAdapter::VERSION
  spec.authors = ["Khairi"]
  spec.email   = ["khairi@labs.my"]

  spec.summary     = "ActiveRecord adapter for NodeDB — the distributed multi-model database"
  spec.description = "Connects Rails to NodeDB via PostgreSQL wire protocol (pgwire) and exposes " \
                     "NodeDB-specific engines: vector search, graph, timeseries, spatial, KV, and FTS."
  spec.homepage    = "https://github.com/mkhairi/activerecord-nodedb-adapter"
  spec.license     = "BSD-2-Clause"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*",
    "docs/**/*",
    "CHANGELOG.md",
    "LICENSE",
    "README.md"
  ]

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "nodedb-ruby",  ">= 0.1.0.alpha.4"
  spec.add_dependency "ostruct"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
end
