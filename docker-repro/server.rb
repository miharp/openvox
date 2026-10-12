require 'socket'
require 'digest'
require 'time'

MODE_FILE = '/tmp/server_mode'
BODY_FILE = '/tmp/server_body'

server = TCPServer.new('0.0.0.0', 8000)
puts "listening on 0.0.0.0:8000"

loop do
  client = server.accept
  begin
    request_line = client.gets
    method = request_line.to_s.split(' ').first || 'GET'

    # Drain (and ignore) the request headers.
    while (line = client.gets)
      break if line == "\r\n" || line == "\n"
    end

    mode = File.exist?(MODE_FILE) ? File.read(MODE_FILE).strip : 'none'
    body = File.read(BODY_FILE)

    headers = [
      'HTTP/1.1 200 OK',
      'Content-Type: text/plain',
      "Content-Length: #{body.bytesize}",
      'Connection: close'
    ]

    case mode
    when 'none'
      # No cache-validation headers at all. Reproduces the real-world case
      # from puppetlabs/puppet#9553 (Artifactory behind Cloudflare/Varnish).
    when 'last_modified_churn'
      # A server that regenerates Last-Modified on every request even
      # though the body hasn't changed (e.g. a dynamic backend behind a
      # caching proxy).
      headers << "Last-Modified: #{Time.now.httpdate}"
    when 'sha256'
      headers << "X-Checksum-Sha256: #{Digest::SHA256.hexdigest(body)}"
    when 'etag_unused'
      # A strong ETag that looks like a real digest, but the resource under
      # test never requests checksum => etag, so #collect never consults
      # it -- reproduces raw.githubusercontent.com, which sends an ETag but
      # no Last-Modified.
      headers << "ETag: \"#{Digest::SHA256.hexdigest(body)}\""
    when 'get_fails'
      # HEAD succeeds (with no validators), but any GET returns 500. A run
      # against this origin must FAIL, not report a clean no-change run:
      # with no headers to trust, "we could not verify" is a failure, never
      # silently "unchanged".
      if method != 'HEAD'
        err = "boom\n"
        client.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: #{err.bytesize}\r\nConnection: close\r\n\r\n#{err}")
        next
      end
    end

    response = "#{headers.join("\r\n")}\r\n\r\n"
    response += body if method != 'HEAD'

    client.write(response)
  rescue StandardError => e
    warn "server error: #{e}"
  ensure
    client.close
  end
end
