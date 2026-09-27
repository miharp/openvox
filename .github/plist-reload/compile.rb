# Compiles a bit of Puppet code against ./modules into a JSON catalog, so the
# agent can apply it with use_cached_catalog and no server.
# usage: compile.rb <certname> <puppet code> <out.json>
require 'puppet'
require 'json'
require 'tmpdir'

certname, code, out = ARGV
dir = File.expand_path(__dir__)
Puppet.initialize_settings(['--modulepath', File.join(dir, 'modules'), '--confdir', Dir.mktmpdir, '--vardir', Dir.mktmpdir])
Puppet[:code] = code

node = Puppet::Node.new(certname, environment: 'production')
node.environment = Puppet.lookup(:environments).get('production')
Puppet.override(current_environment: node.environment) do
  catalog = Puppet::Parser::Compiler.compile(node).to_resource
  File.write(out, JSON.pretty_generate(catalog.to_data_hash))
end
puts "compiled #{out}"
