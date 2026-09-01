require 'spec_helper'
require 'net/ssh'
require 'tmpdir'
require 'open3'

# net-ssh cannot read a key in the `-----BEGIN OPENSSH PRIVATE KEY-----`
# container without ed25519/bcrypt_pbkdf: key_factory.rb:198 raises
# NotImplementedError before it ever looks at the algorithm inside. That
# container is what every modern ssh-keygen writes, RSA included, so without
# those gems odysseus can only authenticate via ssh-agent.
#
# This exercises net-ssh rather than odysseus code on purpose: the bug is a
# missing dependency, and the only honest test of a dependency is to use it.
RSpec.describe 'SSH private key formats' do
  def generate(type, passphrase)
    path = File.join(@dir, "id_#{type}_#{passphrase.empty? ? 'plain' : 'locked'}")
    args = ['ssh-keygen', '-t', type, '-N', passphrase, '-f', path, '-q', '-C', 'spec']
    args += ['-b', '2048'] if type == 'rsa'
    _, err, status = Open3.capture3(*args)
    raise "ssh-keygen failed: #{err}" unless status.success?

    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # ask_passphrase: false is what non_interactive: true gives the key loader.
  def load(path)
    Net::SSH::KeyFactory.load_private_key(path, nil, false)
  end

  %w[ed25519 rsa].each do |type|
    it "reads an unencrypted #{type} key written by ssh-keygen" do
      expect { load(generate(type, '')) }.not_to raise_error
    end

    # Not a passphrase problem when the gems are missing: it fails to parse the
    # container before decryption is even attempted. Pinning the error class
    # keeps the two failure modes distinguishable.
    it "fails to decrypt, not to parse, an encrypted #{type} key" do
      expect { load(generate(type, 'hunter2')) }
        .to(raise_error { |e| expect(e).not_to be_a(NotImplementedError) })
    end
  end
end
