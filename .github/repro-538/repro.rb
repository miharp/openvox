require 'socket'
h = ARGV[0]
fams = Addrinfo.getaddrinfo(h, 443, nil, :STREAM).map { |a| a.ipv6? ? 'v6' : 'v4' }.uniq
res = Hash.new(0)
5.times do
  pid = fork { $stderr.reopen('/dev/null'); Addrinfo.getaddrinfo(h, 443, nil, :STREAM); exit!(0) }
  _, s = Process.waitpid2(pid)
  res[s.signaled? ? "CRASH" : "ok"] += 1
end
puts "#{h} #{fams} => #{res}"
