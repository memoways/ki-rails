$:.push File.expand_path("../lib", __FILE__)
require "ki/rails/version"

Gem::Specification.new do |s|
  s.name        = "ki-rails"
  s.version     = Ki::Rails::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Amos Wenger"]
  s.email       = ["amos@lockfree.ch"]
  s.homepage    = "https://github.com/memoways/ki-rails"
  s.summary     = %q{Ki adapter for the Rails asset pipeline.}
  s.description = %q{Ki adapter for the Rails asset pipeline.}

  s.add_dependency 'therubyracer'
  s.add_runtime_dependency 'railties',      '>= 4.0.0', '< 5.0'

  s.require_paths = ["lib"]
  s.license = "MIT"
end

