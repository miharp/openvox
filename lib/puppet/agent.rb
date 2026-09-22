# frozen_string_literal: true

require_relative '../puppet/application'
require_relative '../puppet/error'
require_relative '../puppet/util/at_fork'

require 'timeout'

# A general class for triggering a run of another
# class.
class Puppet::Agent
  require_relative 'agent/locker'
  include Puppet::Agent::Locker

  require_relative 'agent/disabler'
  include Puppet::Agent::Disabler

  require_relative '../puppet/util/splayer'
  include Puppet::Util::Splayer

  # Special exception class used to signal an agent run has timed out.
  class RunTimeoutError < Exception # rubocop:disable Lint/InheritException
  end

  # Arguments appended to the original command line when respawning a
  # one-time agent process on platforms where forking is unsafe. They are
  # appended last so that they override any conflicting arguments the
  # process was originally started with. Splay and waiting for the
  # certificate have already happened in the parent. `--detailed-exitcodes`
  # makes the child report the run result in its exit status, matching what
  # a forked run returns.
  ONETIME_ARGS = %w[--onetime --no-daemonize --no-splay --detailed-exitcodes].freeze

  attr_reader :client_class, :client, :should_fork

  # The command line (subcommand and arguments) this agent was started
  # with, needed to respawn the agent on platforms where the run cannot
  # fork. Set by the application, like Puppet::Daemon#argv.
  attr_accessor :argv

  def initialize(client_class, should_fork = true)
    @should_fork = can_fork? && should_fork
    @should_exec = exec_instead_of_fork? && should_fork
    @client_class = client_class
    # Captured now, before the daemon changes directory to /, so that the
    # respawned process resolves relative arguments (`--config
    # conf/puppet.conf`) the same way this one did.
    @working_directory = begin
      Dir.pwd
    rescue SystemCallError
      nil
    end
  end

  def can_fork?
    Puppet.features.posix? && RUBY_PLATFORM != 'java'
  end

  # Whether scheduled runs should be isolated in a fresh exec'd process
  # instead of a forked copy of this one.
  #
  # On macOS 26 and later, a forked child that has not exec'd crashes inside
  # getaddrinfo(3) when it resolves a hostname that has no IPv6 address, once
  # the parent has resolved a name itself: the resolver's NAT64 check calls
  # into os_log, which reads a shared mapping the child does not have. The
  # daemon parent resolves the server name whenever it refreshes the CA or
  # CRL, after which every forked run dies. A fresh process is not affected.
  # See https://github.com/OpenVoxProject/openvox/issues/538
  def exec_instead_of_fork?
    can_fork? && Puppet::Util::Platform.darwin?
  end

  def needing_restart?
    Puppet::Application.restart_requested?
  end

  # Perform a run with our client.
  def run(client_options = {})
    if disabled?
      log_disabled_message
      return
    end

    result = nil
    block_run = Puppet::Application.controlled_run do
      # splay may sleep for awhile when running onetime! If not onetime, then
      # the job scheduler splays (only once) so that agents assign themselves a
      # slot within the splay interval.
      do_splay = client_options.fetch(:splay, Puppet[:splay])
      if do_splay
        splay(do_splay)

        if disabled?
          log_disabled_message
          break
        end
      end

      # waiting for certs may sleep for awhile depending on onetime, waitforcert and maxwaitforcert!
      # this needs to happen before forking so that if we fail to obtain certs and try to exit, then
      # we exit the main process and not the forked child.
      ssl_context = wait_for_certificates(client_options)

      new_process_command = @should_exec ? command_for_new_process(client_options) : nil
      result = if new_process_command
                 run_in_new_process(new_process_command, client_options, ssl_context)
               else
                 run_in_process_or_fork(client_options, ssl_context)
               end
      true
    end
    Puppet.notice _("Shutdown/restart in progress (%{status}); skipping run") % { status: Puppet::Application.run_status.inspect } unless block_run
    result
  end

  def run_in_process_or_fork(client_options, ssl_context)
    wait_for_lock_deadline = nil
    run_in_fork(should_fork) do
      with_client(client_options[:transaction_uuid], client_options[:job_id]) do |client|
        client_args = client_options.merge(:pluginsync => Puppet::Configurer.should_pluginsync?)
        begin
          # lock may sleep for awhile depending on waitforlock and maxwaitforlock!
          lock do
            if disabled?
              log_disabled_message
              nil
            else
              # NOTE: Timeout is pretty heinous as the location in which it
              # throws an error is entirely unpredictable, which means that
              # it can interrupt code blocks that perform cleanup or enforce
              # sanity. The only thing an OpenVox agent should do after this
              # error is thrown is die with as much dignity as possible.
              Timeout.timeout(Puppet[:runtimeout], RunTimeoutError) do
                Puppet.override(ssl_context: ssl_context) do
                  client.run(client_args)
                end
              end
            end
          end
        rescue Puppet::LockError
          now = Time.now.to_i
          wait_for_lock_deadline ||= now + Puppet[:maxwaitforlock]

          if Puppet[:waitforlock] < 1
            Puppet.notice _("Run of %{client_class} already in progress; skipping  (%{lockfile_path} exists)") % { client_class: client_class, lockfile_path: lockfile_path }
            nil
          elsif now >= wait_for_lock_deadline
            Puppet.notice _("Exiting now because the maxwaitforlock timeout has been exceeded.")
            nil
          else
            Puppet.info _("Another OpenVox instance is already running; --waitforlock flag used, waiting for running instance to finish.")
            Puppet.info _("Will try again in %{time} seconds.") % { time: Puppet[:waitforlock] }
            sleep Puppet[:waitforlock]
            retry
          end
        rescue RunTimeoutError => detail
          Puppet.log_exception(detail, _("Execution of %{client_class} did not complete within %{runtimeout} seconds and was terminated.") %
            { client_class: client_class, runtimeout: Puppet[:runtimeout] })
          nil
        rescue StandardError => detail
          Puppet.log_exception(detail, _("Could not run %{client_class}: %{detail}") % { client_class: client_class, detail: detail })
          nil
        ensure
          Puppet.runtime[:http].close
        end
      end
    end
  end

  def stopping?
    Puppet::Application.stop_requested?
  end

  def run_in_fork(forking = true)
    return yield unless forking or Puppet.features.windows?

    atForkHandler = Puppet::Util::AtFork.get_handler

    atForkHandler.prepare

    begin
      child_pid = Kernel.fork do
        atForkHandler.child
        $0 = _("puppet agent: applying configuration")
        begin
          exit(yield || 1)
        rescue NoMemoryError
          exit(254)
        end
      end
    ensure
      atForkHandler.parent
    end

    _, status = wait_for_child(child_pid)
    status.exitstatus
  end

  # Wait for the forked child to exit. The child enforces `runtimeout` on its
  # own run, but it may fail to exit afterwards (a stranded thread, a hung
  # subprocess, etc.). Without a deadline here, the parent blocks forever and
  # the agent stops checking in. Once the run timeout plus a grace period has
  # elapsed, the child is killed so the daemon can carry on.
  def wait_for_child(child_pid)
    deadline = child_deadline
    return Process.waitpid2(child_pid) unless deadline

    loop do
      result = Process.waitpid2(child_pid, Process::WNOHANG)
      return result if result

      if monotonic_now >= deadline
        Puppet.err _("Agent run (pid %{pid}) did not exit within %{timeout} seconds of the run timeout, killing it") %
                   { pid: child_pid, timeout: child_grace_period }
        begin
          Process.kill(:KILL, child_pid)
        rescue Errno::ESRCH
          # The child exited between the last check and the kill.
        end
        return Process.waitpid2(child_pid)
      end

      sleep 1
    end
  end

  # After the run timeout fires inside the child, it may still need to send
  # its report, which is bounded by the HTTP connect and read timeouts.
  def child_grace_period
    Puppet[:http_connect_timeout] + Puppet[:http_read_timeout]
  end

  # Returns the absolute monotonic deadline for the child, or nil when
  # `runtimeout` is disabled.
  def child_deadline
    runtimeout = Puppet[:runtimeout]
    return nil if runtimeout.nil? || runtimeout <= 0

    monotonic_now + runtimeout + child_grace_period
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  private

  # Build the command line used to respawn this agent as a fresh one-time
  # process: the running ruby, loading this Puppet (so a checkout run with
  # `ruby -Ilib` respawns the same code) and running the same entry point
  # as bin/puppet, with the original arguments and ONETIME_ARGS. Nothing
  # depends on how this process was started, which may not have been
  # through bin/puppet at all. Other load path or environment
  # customizations reach the child through the inherited RUBYLIB and
  # RUBYOPT. Returns nil if the run cannot be expressed as a command line,
  # because the original invocation is unknown (argv unset) or the caller
  # passed client options that have no command line equivalent. The run is
  # then forked as usual.
  def command_for_new_process(client_options)
    return nil if argv.nil?
    return nil if client_options[:transaction_uuid] || client_options[:job_id]

    [ruby_path, '-I', puppet_lib_dir, '-rpuppet/util/command_line', '-e', 'Puppet::Util::CommandLine.new.execute', '--'] + argv + ONETIME_ARGS
  end

  # Run the agent in a freshly exec'd one-time process instead of a forked
  # copy of this one. Uses spawn (fork+exec) so that the child never runs
  # Ruby code between fork and exec. The child takes the agent lock, honors
  # runtimeout and reports the run result in its exit status via
  # --detailed-exitcodes, mirroring what a forked run returns. If the
  # process cannot be started at all, fall back to a forked run rather than
  # skip the run.
  def run_in_new_process(command, client_options, ssl_context)
    Puppet.debug { "Spawning one-time agent run: '#{command.join(' ')}'" }
    options = @working_directory ? { chdir: @working_directory } : {}
    child_pid = Kernel.spawn(*command, **options)
    exit_code = Process.waitpid2(child_pid)
    exit_code[1].exitstatus
  rescue SystemCallError => detail
    Puppet.log_exception(detail, _("Could not start a new process for the %{client_class} run, forking instead: %{detail}") % { client_class: client_class, detail: detail })
    run_in_process_or_fork(client_options, ssl_context)
  end

  # Unquoted, unlike Puppet::Util::Execution.ruby_path, because it is passed
  # to spawn as an argument rather than through a shell.
  def ruby_path
    File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'] + RbConfig::CONFIG['EXEEXT'])
  end

  def puppet_lib_dir
    File.expand_path('..', __dir__)
  end

  # Create and yield a client instance, keeping a reference
  # to it during the yield.
  def with_client(transaction_uuid, job_id = nil)
    begin
      @client = client_class.new(transaction_uuid, job_id)
    rescue StandardError => detail
      Puppet.log_exception(detail, _("Could not create instance of %{client_class}: %{detail}") % { client_class: client_class, detail: detail })
      return
    end
    yield @client
  ensure
    @client = nil
  end

  def wait_for_certificates(options)
    waitforcert = options[:waitforcert] || (Puppet[:onetime] ? 0 : Puppet[:waitforcert])
    sm = Puppet::SSL::StateMachine.new(waitforcert: waitforcert, onetime: Puppet[:onetime])
    sm.ensure_client_certificate
  end

  def log_disabled_message
    Puppet.notice _("Skipping run of %{client_class}; administratively disabled (Reason: '%{disable_message}');\nUse 'puppet agent --enable' to re-enable.") % { client_class: client_class, disable_message: disable_message }
  end
end
