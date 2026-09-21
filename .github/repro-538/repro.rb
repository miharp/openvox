require 'socket'
require 'timeout'
h = ARGV[0]
fams = Addrinfo.getaddrinfo(h, 443, nil, :STREAM).map { |a| a.ipv6? ? 'v6' : 'v4' }.uniq
res = Hash.new(0)
5.times do
  pid = fork { $stderr.reopen('/dev/null'); Addrinfo.getaddrinfo(h, 443, nil, :STREAM); exit!(0) }
  begin
    _, s = Timeout.timeout(15) { Process.waitpid2(pid) }
    res[s.signaled? ? "CRASH" : "ok"] += 1
  rescue Timeout::Error
    # ruby >= 3.3 resolves on a helper thread, so the child can hang instead of dying
    Process.kill(:KILL, pid)
    Process.waitpid(pid)
    res["HANG"] += 1
  end
end
puts "#{RUBY_VERSION} #{h} #{fams} => #{res}"
