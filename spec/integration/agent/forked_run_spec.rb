require 'spec_helper'
require 'puppet/agent'
require 'puppet/configurer'
require 'puppet/daemon'
require 'puppet/ssl/state_machine'

# These examples fork a real child, as the daemon does, because the
# behaviour under test is the interaction between the parent's deadline
# (Puppet::Agent#wait_for_child) and work the child now does before its
# own run timeout starts (waiting for a certificate, since #683).
describe Puppet::Agent, "forked run", :if => Puppet.features.posix? && RUBY_PLATFORM != 'java' do
  include PuppetSpec::Files

  class ForkedRunTestClient
    def initialize(transaction_uuid = nil, job_id = nil); end

    def run(options = {})
      sleep(options[:sleep] || 0)
      0
    end
  end

  let(:ssl_context) { Puppet::SSL::SSLContext.new }
  let(:agent) { Puppet::Agent.new(ForkedRunTestClient, true) }

  before :each do
    Puppet[:ssldir] = tmpdir('ssl')
    Puppet.settings.use(:main, :agent, :ssl)
    Puppet[:http_connect_timeout] = '1s'
    Puppet[:http_read_timeout] = '1s'
    allow(Puppet).to receive(:err).and_call_original
  end

  context "when the child is waiting for a certificate" do
    it "honours maxwaitforcert instead of killing the child at the run deadline" do
      # Parent deadline: runtimeout + connect + read = 3s. The certificate
      # wait is allowed 4s, so it must outlive the run deadline.
      Puppet[:runtimeout] = '1s'
      Puppet[:waitforcert] = '1s'
      Puppet[:maxwaitforcert] = '4s'

      # Unsigned CSR: every pass through the state machine lands in Wait,
      # which gives up with exit(1) once maxwaitforcert is exceeded.
      allow_any_instance_of(Puppet::SSL::StateMachine::NeedCACerts).to receive(:next_state) do |state|
        Puppet::SSL::StateMachine::Wait.new(state.instance_variable_get(:@machine))
      end

      expect(Puppet).not_to receive(:err).with(/did not exit within .* killing it/)
      expect { agent.run }.to exit_with(1)
    end

    it "does not exit the daemon when only the child is signalled" do
      Puppet[:runtimeout] = '5s'
      daemon = Puppet::Daemon.new(agent, Puppet::Util::Pidlock.new(tmpfile('agent.pid')))
      previous = [:INT, :TERM, :HUP, :USR1, :USR2].to_h { |sig| [sig, Signal.trap(sig, 'DEFAULT')] }
      daemon.set_signal_traps

      parent_pid = Process.pid
      machine = instance_double(Puppet::SSL::StateMachine)
      allow(Puppet::SSL::StateMachine).to receive(:new).and_return(machine)
      allow(machine).to receive(:ensure_client_certificate) do
        # The child inherits the daemon's traps. TERM here runs
        # Puppet::Daemon#stop, which calls exit. Only ever signal the
        # child: before #683 this wait ran in the parent.
        if Process.pid != parent_pid
          Process.kill(:TERM, Process.pid)
          sleep 5
        end
        ssl_context
      end

      begin
        expect { agent.run }.not_to raise_error
      ensure
        previous.each { |sig, handler| Signal.trap(sig, handler) }
      end
    end
  end

  context "when the run starts after a certificate wait" do
    it "gives the run its full runtimeout" do
      # Parent deadline: 2s + 1s + 1s = 4s from the fork. The child waits 3s
      # for a certificate and then runs for 1.5s, well under runtimeout.
      Puppet[:runtimeout] = '2s'

      machine = instance_double(Puppet::SSL::StateMachine)
      allow(Puppet::SSL::StateMachine).to receive(:new).and_return(machine)
      allow(machine).to receive(:ensure_client_certificate) { sleep 3; ssl_context }

      expect(Puppet).not_to receive(:err).with(/did not exit within .* killing it/)
      expect(agent.run(sleep: 1.5)).to eq(0)
    end
  end
end
