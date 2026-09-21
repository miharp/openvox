# Writes a throwaway CA, CRL, key and client cert into an agent ssldir so that
# Puppet::SSL::StateMachine#ensure_client_certificate passes with no server.
# usage: fake_ssl.rb <ssldir> <certname>
require 'openssl'
require 'fileutils'

ssldir, certname = ARGV
now = Time.now

def cert(subject, issuer_cert, issuer_key, key, serial, ca, now)
  c = OpenSSL::X509::Certificate.new
  c.version = 2
  c.serial = serial
  c.subject = OpenSSL::X509::Name.parse(subject)
  c.issuer = issuer_cert ? issuer_cert.subject : c.subject
  c.public_key = key.public_key
  c.not_before = now - 3600
  c.not_after = now + (5 * 365 * 86_400)
  ef = OpenSSL::X509::ExtensionFactory.new
  ef.subject_certificate = c
  ef.issuer_certificate = issuer_cert || c
  c.add_extension(ef.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
  c.add_extension(ef.create_extension('keyUsage', ca ? 'keyCertSign,cRLSign' : 'digitalSignature,keyEncipherment', true))
  c.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
  c.sign(issuer_key, OpenSSL::Digest.new('SHA256'))
  c
end

ca_key = OpenSSL::PKey::RSA.new(2048)
ca = cert('/CN=repro-538 fake CA', nil, ca_key, ca_key, 1, true, now)
key = OpenSSL::PKey::RSA.new(2048)
client = cert("/CN=#{certname}", ca, ca_key, key, 2, false, now)

crl = OpenSSL::X509::CRL.new
crl.version = 1
crl.issuer = ca.subject
crl.last_update = now - 3600
crl.next_update = now + 86_400
crl.add_extension(OpenSSL::X509::Extension.new('crlNumber', OpenSSL::ASN1::Integer(1)))
crl.sign(ca_key, OpenSSL::Digest.new('SHA256'))

FileUtils.mkdir_p(%w[certs private_keys public_keys].map { |d| File.join(ssldir, d) })
File.write(File.join(ssldir, 'certs', 'ca.pem'), ca.to_pem)
File.write(File.join(ssldir, 'crl.pem'), crl.to_pem)
File.write(File.join(ssldir, 'certs', "#{certname}.pem"), client.to_pem)
File.write(File.join(ssldir, 'private_keys', "#{certname}.pem"), key.to_pem, perm: 0o600)
File.write(File.join(ssldir, 'public_keys', "#{certname}.pem"), key.public_key.to_pem)
puts "wrote fake PKI for #{certname} to #{ssldir}"
