# Compiles profile::puppet_launchd into a JSON catalog, so the agent daemon
# can apply it with use_cached_catalog and no server.
# usage: compile.rb <certname> <reload_method> <reload_delay> <out.json>
require 'puppet'
require 'json'

certname, method, delay, out = ARGV
dir = File.expand_path(__dir__)
Puppet.initialize_settings(['--modulepath', File.join(dir, 'modules'), '--confdir', Dir.mktmpdir, '--vardir', Dir.mktmpdir])
Puppet[:code] = "class { 'profile::puppet_launchd': reload_method => '#{method}', reload_delay => #{delay} }"

node = Puppet::Node.new(certname, environment: 'production')
node.environment = Puppet.lookup(:environments).get('production')
Puppet.override(current_environment: node.environment) do
  catalog = Puppet::Parser::Compiler.compile(node).to_resource
  File.write(out, JSON.pretty_generate(catalog.to_data_hash))
end
puts "compiled #{out}"
