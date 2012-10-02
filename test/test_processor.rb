require 'helper'
require 'sidekiq/processor'

class TestProcessor < MiniTest::Unit::TestCase
  TestException = Class.new(StandardError)
  TEST_EXCEPTION = TestException.new("kerboom!")

  describe 'with mock setup' do
    before do
      $invokes = 0
      @boss = MiniTest::Mock.new
      @processor = ::Sidekiq::Processor.new(@boss)
      Celluloid.logger = nil
      Sidekiq.redis = REDIS
    end

    class MockWorker
      include Sidekiq::Worker
      def perform(args)
        raise TEST_EXCEPTION if args == 'boom'
        args.pop if args.is_a? Array
        $invokes += 1
      end
    end

    class SansNotificationMockWorker < MockWorker
      def should_handle_exception?(exception, retry_count)
        false
      end
    end

    it 'processes as expected' do
      msg = Sidekiq.dump_json({ 'class' => MockWorker.to_s, 'args' => ['myarg'] })
      @boss.expect(:processor_done!, nil, [@processor])
      @processor.process(msg, 'default')
      @boss.verify
      assert_equal 1, $invokes
    end

    describe 'handling exceptions' do
      before do
        @old_logger = Sidekiq.logger
        @str_logger = StringIO.new
        Sidekiq.logger = Logger.new(@str_logger)
        Sidekiq.logger.level = Logger::WARN
      end

      it 'passes exceptions to ExceptionHandler' do
        msg = Sidekiq.dump_json({ 'class' => MockWorker.to_s, 'args' => ['boom'] })
        begin
          @processor.process(msg, 'default')
          flunk "Expected #process to raise exception"
        rescue TestException
        end

        assert_equal 0, $invokes
        @str_logger.rewind
        log = @str_logger.read
        assert_match /Exception/, log, "Exception wasn't handled"
      end

      it 'does not pass exceptions to ExceptionHandler when specified by worker' do
        msg = Sidekiq.dump_json({ 'class' => SansNotificationMockWorker.to_s, 'args' => ['boom'] })
        begin
          @processor.process(msg, 'default')
          flunk "Expected #process to raise exception"
        rescue TestException
        end

        assert_equal 0, $invokes
        @str_logger.rewind
        log = @str_logger.read
        assert_equal 0, log.size
      end

    end

    it 're-raises exceptions after handling' do
      msg = Sidekiq.dump_json({ 'class' => MockWorker.to_s, 'args' => ['boom'] })
      re_raise = false

      begin
        @processor.process(msg, 'default')
      rescue TestException
        re_raise = true
      end

      assert re_raise, "does not re-raise exceptions after handling"
    end

    it 'does not modify original arguments' do
      msg = { 'class' => MockWorker.to_s, 'args' => [['myarg']] }
      msgstr = Sidekiq.dump_json(msg)
      processor = ::Sidekiq::Processor.new(@boss)
      @boss.expect(:processor_done!, nil, [processor])
      processor.process(msgstr, 'default')
      assert_equal [['myarg']], msg['args']
    end
  end
end
