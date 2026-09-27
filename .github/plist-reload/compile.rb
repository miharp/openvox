# Compiles a bit of Puppet code against ./modules into a JSON catalog, so the
# agent can apply it with use_cached_catalog and no server.
# Extra module directories can be added with MODULEPATH.
# usage: compile.rb <certname> <puppet code> <out.json>
require 'puppet'
require 'json'
require 'tmpdir'

certname, code, out = ARGV
dir = File.expand_path(__dir__)
modulepath = [File.join(dir, 'modules'), ENV['MODULEPATH']].compact.join(':')
Puppet.initialize_settings(['--modulepath', modulepath, '--confdir', Dir.mktmpdir, '--vardir', Dir.mktmpdir])
Puppet[:code] = code

# Facts of the host doing the compile (the CI runner), for classes that
# branch on them.
facts = Puppet::Node::Facts.indirection.find(certname)
node = Puppet::Node.new(certname, facts: facts, environment: 'production')
node.environment = Puppet.lookup(:environments).get('production')
Puppet.override(current_environment: node.environment) do
  catalog = Puppet::Parser::Compiler.compile(node).to_resource
  File.write(out, JSON.pretty_generate(catalog.to_data_hash))
end
puts "compiled #{out}"
