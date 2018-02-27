require 'logging'
require 'rspec'
require 'tempfile'
require 'rspec/core/rake_task'
require 'bosh/dev/sandbox/nginx'
require 'bosh/dev/sandbox/services/connection_proxy_service'
require 'bosh/dev/sandbox/workspace'
require 'common/thread_pool'
require 'bosh/dev/sandbox/services/uaa_service'
require 'bosh/dev/sandbox/services/config_server_service'
require 'bosh/dev/legacy_agent_manager'
require 'bosh/dev/verify_multidigest_manager'
require 'bosh/dev/gnatsd_manager'
require 'bosh/dev/test_runner'
require 'parallel_tests/tasks'
require 'fileutils'

namespace :spec do
  namespace :integration do
    desc 'Run BOSH gocli integration tests against a local sandbox'
    task :gocli => :install_dependencies do
      run_integration_specs(spec_path: 'spec/gocli/integration')
    end

    desc 'Run health monitor integration tests against a local sandbox'
    task :health_monitor => :install_dependencies do
      run_integration_specs(spec_path: 'spec/gocli/integration', tags: 'hm')
    end

    desc 'Run BOSH gocli upgrade tests against a local sandbox'
    task :upgrade => :install_dependencies do
      run_integration_specs(spec_path: 'spec/gocli/integration_upgrade')
    end

    desc 'Install BOSH integration test dependencies (currently Nginx, UAA, and Config Server)'
    task :install_dependencies do
      FileUtils.mkdir_p("tmp")
      File.open("tmp/compilation.log", "w") do |compilation_log|
        unless ENV['SKIP_DEPS'] == 'true'
          unless ENV['SKIP_NGINX'] == 'true'
            nginx = Bosh::Dev::Sandbox::Nginx.new(Bosh::Core::Shell.new(compilation_log))
            install_with_retries(nginx)
          end

          unless ENV['SKIP_TCP_PROXY_NGINX'] == 'true'
            tcp_proxy_nginx = Bosh::Dev::Sandbox::TCPProxyNginx.new(Bosh::Core::Shell.new(compilation_log))
            install_with_retries(tcp_proxy_nginx)
          end

          unless ENV['SKIP_UAA'] == 'true'
            Bosh::Dev::Sandbox::UaaService.install
          end

          unless ENV['SKIP_CONFIG_SERVER'] == 'true'
            Bosh::Dev::Sandbox::ConfigServerService.install(Bosh::Core::Shell.new(compilation_log))
          end

          unless ENV['SKIP_LEGACY_AGENTS'] == 'true'
            Bosh::Dev::LegacyAgentManager.install
          end

          unless ENV['SKIP_VERIFY_MULTIDIGEST'] == 'true'
            Bosh::Dev::VerifyMultidigestManager.install(Bosh::Core::Shell.new(compilation_log))
          end

          unless ENV['SKIP_GNATSD'] == 'true'
            Bosh::Dev::GnatsdManager.install(Bosh::Core::Shell.new(compilation_log))
          end
        end

        compile_dependencies
      end
    end

    desc 'Download BOSH Agent. Use only for local dev environment'
    task :download_bosh_agent do
      trap('INT') { exit }
      cmd = 'mkdir -p ./go/src/github.com/cloudfoundry && '
      cmd += 'cd ./go/src/github.com/cloudfoundry && '
      cmd += 'rm -rf bosh-agent && '
      cmd += 'git clone https://github.com/cloudfoundry/bosh-agent.git'
      sh(cmd)
    end

    def install_with_retries(to_install)
      retries = 3
      begin
        to_install.install
      rescue
        retries -= 1
        retry if retries > 0
        raise
      end
    end

    def run_integration_specs(run_options={})
      Bosh::Dev::Sandbox::Workspace.clean

      num_processes   = ENV['NUM_GROUPS']
      num_processes ||= ENV['TRAVIS'] ? 4 : nil

      options = {}
      options.merge!(run_options)
      options[:count] = num_processes if num_processes
      options[:group] = ENV['GROUP'] if ENV['GROUP']

      spec_path = options.fetch(:spec_path)

      puts "Launching parallel execution of #{spec_path}"
      run_in_parallel(spec_path, options)
    end

    def run_in_parallel(test_path, options={})
      spec_path = ENV['SPEC_PATH'] || ''
      count = " -n #{options[:count]}" unless options[:count].to_s.empty?
      group = " --only-group #{options[:group]}" unless options[:group].to_s.empty?
      tag = "SPEC_OPTS='--tag #{options[:tags]}'" unless options[:tags].nil?
      command = begin
        if '' != spec_path
          "#{tag} https_proxy= http_proxy= bundle exec rspec #{spec_path}"
        else
          "#{tag} https_proxy= http_proxy= bundle exec parallel_test '#{test_path}'#{count}#{group} --group-by filesize --type rspec"
        end
      end
      puts command
      abort unless system(command)
    end

    def compile_dependencies
      sh('go/src/github.com/cloudfoundry/bosh-agent/bin/build')
    end
  end

  task :integration_gocli => %w(spec:integration:gocli)

  task :upgrade => %w(spec:integration:upgrade)

  desc 'Run all release unit tests (ERB templates)'
  task :release_unit do
    puts "Release unit tests (ERB templates)"
    sh("cd .. && rspec --tty --backtrace -c -f p spec/")
  end

  desc 'Run template test unit tests (i.e. Bosh::Template::Test)'
  task :template_test_unit do
    puts "Template test unit tests (ERB templates)"
    sh("rspec bosh-template/spec/assets/template-test-release/src/spec/config.erb_spec.rb")
  end

  namespace :unit do
    runner = Bosh::Dev::TestRunner.new

    desc 'Run all unit tests for ruby components'
    task :ruby do
      trap('INT') { exit }
      runner.ruby
    end

    runner.unit_builds.each do |build|
      desc "Run unit tests for the #{build} component"
      task build.sub(/^bosh[_-]/, '').intern do
        trap('INT') { exit }
        runner.unit_exec(build)
      end
    end

    desc 'Run all migrations tests'
    task :migrations do
      trap('INT') { exit }
      cmd = 'rspec --tty --backtrace -c -f p ./spec/unit/db/migrations/'
      sh("cd bosh-director && #{cmd}")
    end
  end

  desc "Run all unit tests"
  task :unit => %w(spec:release_unit spec:unit:ruby spec:template_test_unit)
end

desc 'Run unit and gocli integration specs'
task :spec => %w(spec:unit spec:integration:gocli)
