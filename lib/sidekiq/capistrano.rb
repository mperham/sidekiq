Capistrano::Configuration.instance.load do
  before "deploy:update_code", "sidekiq:quiet"
  after "deploy:stop",    "sidekiq:stop"
  after "deploy:start",   "sidekiq:start"
  after "deploy:restart", "sidekiq:restart"

  _cset(:sidekiq_timeout) { 10 }
  _cset(:sidekiq_role)    { :app }
  _cset(:sidekiq_pid)     { "#{current_path}/tmp/pids/sidekiq.pid" }

  namespace :sidekiq do

    desc "Quiet sidekiq (stop accepting new work)"
    task :quiet, :roles => lambda { fetch(:sidekiq_role) }, :on_no_matching_servers => :continue do
      run "if [ -d #{current_path} ] && [ -f #{fetch :sidekiq_pid} ]; then cd #{current_path} && #{fetch(:bundle_cmd, "bundle")} exec sidekiqctl quiet #{fetch :sidekiq_pid} ; fi"
    end

    desc "Stop sidekiq"
    task :stop, :roles => lambda { fetch(:sidekiq_role) }, :on_no_matching_servers => :continue do
      run "if [ -d #{current_path} ] && [ -f #{fetch :sidekiq_pid} ]; then cd #{current_path} && #{fetch(:bundle_cmd, "bundle")} exec sidekiqctl stop #{fetch :sidekiq_pid} #{fetch :sidekiq_timeout} ; fi"
    end

    desc "Start sidekiq"
    task :start, :roles => lambda { fetch(:sidekiq_role) }, :on_no_matching_servers => :continue do
      rails_env = fetch(:rails_env, "production")
      run "cd #{current_path} ; nohup #{fetch(:bundle_cmd, "bundle")} exec sidekiq -e #{rails_env} -C #{current_path}/config/sidekiq.yml -P #{fetch :sidekiq_pid} >> #{current_path}/log/sidekiq.log 2>&1 &", :pty => false
    end

    desc "Restart sidekiq"
    task :restart, :roles => lambda { fetch(:sidekiq_role) }, :on_no_matching_servers => :continue do
      stop
      start
    end

  end
end
