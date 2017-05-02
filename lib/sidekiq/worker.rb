# frozen_string_literal: true
require 'sidekiq/client'
require 'sidekiq/core_ext'

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
    attr_accessor :jid

    def self.included(base)
      raise ArgumentError, "You cannot include Sidekiq::Worker in an ActiveJob: #{base.name}" if base.ancestors.any? {|c| c.name == 'ActiveJob::Base' }

      base.extend(ClassMethods)
      base.class_attribute :sidekiq_options_hash
      base.class_attribute :sidekiq_retry_in_block
      base.class_attribute :sidekiq_retries_exhausted_block
    end

    def logger
      Sidekiq.logger
    end

    # This helper class encapsulates the set options for `set`, e.g.
    #
    #     SomeWorker.set(queue: 'foo').perform_async(....)
    #
    class Setter
      def initialize(opts)
        @opts = opts
      end

      def perform_async(*args)
        @opts['class'.freeze].client_push(@opts.merge!('args'.freeze => args))
      end

      # +interval+ must be a timestamp, numeric or something that acts
      #   numeric (like an activesupport time interval).
      def perform_in(interval, *args)
        int = interval.to_f
        now = Time.now.to_f
        ts = (int < 1_000_000_000 ? now + int : int)

        @opts.merge! 'args'.freeze => args, 'at'.freeze => ts
        # Optimization to enqueue something now that is scheduled to go out now or in the past
        @opts.delete('at'.freeze) if ts <= now
        @opts['class'.freeze].client_push(@opts)
      end
      alias_method :perform_at, :perform_in
    end

    module ClassMethods

      def delay(*args)
        raise ArgumentError, "Do not call .delay on a Sidekiq::Worker class, call .perform_async"
      end

      def delay_for(*args)
        raise ArgumentError, "Do not call .delay_for on a Sidekiq::Worker class, call .perform_in"
      end

      def delay_until(*args)
        raise ArgumentError, "Do not call .delay_until on a Sidekiq::Worker class, call .perform_at"
      end

      def set(options)
        Setter.new(options.merge!('class'.freeze => self))
      end

      def perform_async(*args)
        client_push('class'.freeze => self, 'args'.freeze => args)
      end

      # +interval+ must be a timestamp, numeric or something that acts
      #   numeric (like an activesupport time interval).
      def perform_in(interval, *args)
        int = interval.to_f
        now = Time.now.to_f
        ts = (int < 1_000_000_000 ? now + int : int)

        item = { 'class'.freeze => self, 'args'.freeze => args, 'at'.freeze => ts }

        # Optimization to enqueue something now that is scheduled to go out now or in the past
        item.delete('at'.freeze) if ts <= now

        client_push(item)
      end
      alias_method :perform_at, :perform_in

      def perform_once_in(interval, *args)
        scheduled = Sidekiq::ScheduledSet.new
        int = interval.to_f
        ts = (int < 1_000_000_000 ? now + int : int)
        dup = scheduled.detect do |job|
          job.klass == name &&
          job.score == ts.to_f &&
          job.args == args
        end

        return if dup

        perform_in(ts, *args)
      end
      alias_method :perform_once_at, :perform_once_in

      ##
      # Allows customization for this type of Worker.
      # Legal options:
      #
      #   queue - use a named queue for this Worker, default 'default'
      #   retry - enable the RetryJobs middleware for this Worker, *true* to use the default
      #      or *Integer* count
      #   backtrace - whether to save any error backtrace in the retry payload to display in web UI,
      #      can be true, false or an integer number of lines to save, default *false*
      #   pool - use the given Redis connection pool to push this type of job to a given shard.
      #
      # In practice, any option is allowed.  This is the main mechanism to configure the
      # options for a specific job.
      def sidekiq_options(opts={})
        self.sidekiq_options_hash = get_sidekiq_options.merge(opts.stringify_keys)
      end

      def sidekiq_retry_in(&block)
        self.sidekiq_retry_in_block = block
      end

      def sidekiq_retries_exhausted(&block)
        self.sidekiq_retries_exhausted_block = block
      end

      def get_sidekiq_options # :nodoc:
        self.sidekiq_options_hash ||= Sidekiq.default_worker_options
      end

      def client_push(item) # :nodoc:
        pool = Thread.current[:sidekiq_via_pool] || get_sidekiq_options['pool'.freeze] || Sidekiq.redis_pool
        hash = item.stringify_keys
        Sidekiq::Client.new(pool).push(hash)
      end

    end
  end
end
