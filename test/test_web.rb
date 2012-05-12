require 'helper'
require 'sidekiq'
require 'sidekiq/web'
require 'rack/test'

class TestWeb < MiniTest::Unit::TestCase
  describe 'sidekiq web' do
    include Rack::Test::Methods

    def app
      Sidekiq::Web
    end

    before do
      Sidekiq.redis = REDIS
      Sidekiq.redis {|c| c.flushdb }
    end

    class WebWorker
      include Sidekiq::Worker

      def perform(a, b)
        a + b
      end
    end

    it 'shows active queues' do
      get '/'
      assert_equal 200, last_response.status
      assert_match /Sidekiq is idle/, last_response.body
      refute_match /default/, last_response.body

      assert WebWorker.perform_async(1, 2)

      get '/'
      assert_equal 200, last_response.status
      assert_match /Sidekiq is idle/, last_response.body
      assert_match /default/, last_response.body
      refute_match /foo/, last_response.body

      assert Sidekiq::Client.push('queue' => :foo, 'class' => WebWorker, 'args' => [1, 3])

      get '/'
      assert_equal 200, last_response.status
      assert_match /Sidekiq is idle/, last_response.body
      assert_match /default/, last_response.body
      assert_match /foo/, last_response.body
      assert_match /Backlog: 2/, last_response.body
    end

    it 'handles queues with no name' do
      get '/queues'
      assert_equal 404, last_response.status
    end

    it 'handles missing retry' do
      get '/retries/12391982.123'
      assert_equal 302, last_response.status
    end

    it 'handles queue view' do
      get '/queues/default'
      assert_equal 200, last_response.status
    end

    it 'can delete a queue' do
      Sidekiq.redis do |conn|
        conn.rpush('queue:foo', '{}')
        conn.sadd('queues', 'foo')
      end

      get '/queues/foo'
      assert_equal 200, last_response.status

      post '/queues/foo'
      assert_equal 302, last_response.status

      Sidekiq.redis do |conn|
        refute conn.smembers('queues').include?('foo')
      end
    end

    it 'can display retries' do
      get '/retries'
      assert_equal 200, last_response.status
      assert_match /found/, last_response.body
      refute_match /HardWorker/, last_response.body

      add_retry

      get '/retries'
      assert_equal 200, last_response.status
      refute_match /found/, last_response.body
      assert_match /HardWorker/, last_response.body
    end

    it 'can display a single retry' do
      get '/retries/12938712.123333'
      assert_equal 302, last_response.status
      _, score = add_retry

      get "/retries/#{score}"
      assert_equal 200, last_response.status
      assert_match /HardWorker/, last_response.body
    end

    def add_retry
      msg = { 'class' => 'HardWorker',
              'args' => ['bob', 1, Time.now.to_f],
              'queue' => 'default',
              'error_message' => 'Some fake message',
              'error_class' => 'RuntimeError',
              'retry_count' => 0,
              'failed_at' => Time.now.utc, }
      score = Time.now.to_f
      Sidekiq.redis do |conn|
        conn.zadd('retry', score, Sidekiq.dump_json(msg))
      end
      [msg, score]
    end
  end
end
