source 'http://rubygems.org'
gemspec

gem 'celluloid', :github => 'celluloid/celluloid', :branch => 'revert-actor-locals'
gem 'slim'
gem 'sqlite3', :platform => :mri

group :test do
  gem 'simplecov', :require => false
  gem 'minitest-emoji', :require => false
end

group :development do
  gem 'pry', :platform => :mri
  gem 'shotgun'
  gem 'rack', '~> 1.4.0'
end
