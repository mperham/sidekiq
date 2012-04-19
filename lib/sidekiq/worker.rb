require 'sidekiq/client'

module Sidekiq

  ##
  # Include this module in your worker class and you can easily create
  # asynchronous jobs:
  #
  # class HardWorker
  #   include Sidekiq::Worker
  #
  #   def perform(*args)
  #     # do some work
  #   end
  # end
  #
  # Then in your Rails app, you can do this:
  #
  #   HardWorker.perform_async(1, 2, 3)
  #
  # Note that perform_async is a class method, perform is an instance method.
  module Worker
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def perform_async(*args)
        Sidekiq::Client.push('class' => self, 'args' => args)
      end

      ##
      # Allows customization for this type of Worker.
      # Legal options:
      #
      #   :unique - enable the UniqueJobs middleware for this Worker, default *true*
      #   :queue - use a named queue for this Worker, default 'default'
      #   :retry - enable the RetryJobs middleware for this Worker, default *true*
      def sidekiq_options(opts={})
        @sidekiq_options = get_sidekiq_options.merge(stringify_keys(opts || {}))
      end

      def get_sidekiq_options # :nodoc:
        defined?(@sidekiq_options) ? @sidekiq_options : { 'unique' => true, 'retry' => true, 'queue' => 'default' }
      end

      ##
      # Allows for the customization of the retry logic for this type of Worker
      # Legal options:
      #
      #  :max_count - Maximum number of retries, default 25
      #  :falloff - Fall off algorithm for retry delay, :linear or :exponential, default :exponential
      #  :interval - Number of seconds between :linear retries
      #  :expiration - Do not retry this worker after specified expiration, default nil
      def sidekiq_retry_options(opts={})
        @sidekiq_retry_options = get_sidekiq_retry_options.merge(stringify_keys(opts || {}))
      end

      def get_sidekiq_retry_options # :nodoc:
        @sidekiq_retry_options || {'max_count' => 25, 'falloff' => :exponential, 'expiration' => nil}
      end

      def stringify_keys(hash) # :nodoc:
        hash.keys.each do |key|
          hash[key.to_s] = hash.delete(key)
        end
        hash
      end
    end
  end
end
