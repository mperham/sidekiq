require 'sidekiq/version'
require 'sidekiq/client'
require 'sidekiq/worker'
require 'sidekiq/rails'
require 'sidekiq/redis_connection'
require 'sidekiq/util'

require 'sidekiq/extensions/action_mailer'
require 'sidekiq/extensions/active_record'

module Sidekiq

  DEFAULTS = {
    :queues => [],
    :concurrency => 25,
    :require => '.',
    :environment => nil,
    :timeout => 8,
    :enable_rails_extensions => true,
  }

  def self.options
    @options ||= DEFAULTS.dup
  end

  def self.options=(opts)
    @options = opts
  end

  ##
  # Configuration for Sidekiq server, use like:
  #
  #   Sidekiq.configure_server do |config|
  #     config.redis = { :namespace => 'myapp', :size => 25, :url => 'redis://myhost:8877/mydb' }
  #     config.server_middleware do |chain|
  #       chain.add MyServerHook
  #     end
  #   end
  def self.configure_server
    yield self if server?
  end

  ##
  # Configuration for Sidekiq client, use like:
  #
  #   Sidekiq.configure_client do |config|
  #     config.redis = { :namespace => 'myapp', :size => 1, :url => 'redis://myhost:8877/mydb' }
  #   end
  def self.configure_client
    yield self unless server?
  end

  def self.server?
    defined?(Sidekiq::CLI)
  end

  def self.redis(&block)
    @redis ||= Sidekiq::RedisConnection.create
    raise ArgumentError, "requires a block" if !block
    @redis.with(&block)
  end

  def self.redis=(hash)
    if hash.is_a?(Hash)
      @redis = RedisConnection.create(hash)
    elsif hash.is_a?(ConnectionPool)
      @redis = hash
    else
      raise ArgumentError, "redis= requires a Hash or ConnectionPool"
    end
  end

  def self.client_middleware
    @client_chain ||= Client.default_middleware
    yield @client_chain if block_given?
    @client_chain
  end

  def self.server_middleware
    @server_chain ||= Processor.default_middleware
    yield @server_chain if block_given?
    @server_chain
  end

  def self.load_json(string, options={})
    # Can't reliably detect whether MultiJson responds to load, since it's
    # a reserved word. Use adapter as a proxy for new features.
    if MultiJson.respond_to?(:adapter)
      MultiJson.load(string, options)
    else
      MultiJson.decode(string, options)
    end
  end

  def self.dump_json(object, options={})
    if MultiJson.respond_to?(:dump)
      MultiJson.dump(object, options)
    else
      MultiJson.encode(object, options)
    end
  end

end
