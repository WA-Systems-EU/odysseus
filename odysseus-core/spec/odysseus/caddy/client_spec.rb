# spec/odysseus/caddy/client_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Caddy::Client do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
  let(:client) { described_class.new(ssh: mock_ssh, docker: mock_docker) }

  describe '#running?' do
    it 'delegates to docker client' do
      expect(mock_docker).to receive(:running?).with('odysseus-caddy').and_return(true)
      expect(client.running?).to be true
    end
  end

  describe '#ensure_running' do
    context 'when Caddy is already running' do
      before do
        allow(mock_docker).to receive(:running?).with('odysseus-caddy').and_return(true)
      end

      it 'returns true without starting' do
        expect(mock_docker).not_to receive(:run)
        expect(client.ensure_running).to be true
      end

      it 'does not check for or remove an existing container' do
        expect(mock_docker).not_to receive(:container_exists?)
        expect(mock_docker).not_to receive(:remove)
        client.ensure_running
      end
    end

    context 'when Caddy is absent' do
      before do
        allow(mock_docker).to receive(:running?)
          .with('odysseus-caddy')
          .and_return(false, true) # First check false, then true after start
        allow(mock_docker).to receive(:container_exists?).with('odysseus-caddy').and_return(false)
        allow(mock_ssh).to receive(:user).and_return('root')
        allow(mock_ssh).to receive(:execute) # For network creation
        allow(mock_docker).to receive(:run)
        allow(client).to receive(:sleep) # Don't actually sleep
      end

      it 'creates Docker network with odysseus.managed label' do
        expect(mock_ssh).to receive(:execute)
          .with('docker network create --label odysseus.managed=true odysseus 2>/dev/null || true')
        client.ensure_running
      end

      it 'starts Caddy container with managed label' do
        expect(mock_docker).to receive(:run).with(
          name: 'odysseus-caddy',
          image: 'caddy:2-alpine',
          options: hash_including(
            service: 'odysseus-proxy',
            ports: ['80:80', '443:443', '2019:2019'],
            labels: { 'odysseus.managed' => 'true' }
          )
        )
        client.ensure_running
      end

      it 'returns true after starting' do
        expect(client.ensure_running).to be true
      end

      it 'does not attempt to remove a container' do
        expect(mock_docker).not_to receive(:remove)
        client.ensure_running
      end
    end

    # The container survives a stop under its fixed CONTAINER_NAME, so
    # `docker run --name odysseus-caddy` refuses to reuse it — every deploy
    # after the stop would fail at exactly this point, forever, unless the
    # old container is cleared out of the way first.
    context 'when Caddy is stopped but the container still exists' do
      before do
        allow(mock_docker).to receive(:running?)
          .with('odysseus-caddy')
          .and_return(false, true) # First check false, then true after recreate
        allow(mock_docker).to receive(:container_exists?).with('odysseus-caddy').and_return(true)
        allow(mock_docker).to receive(:remove).with('odysseus-caddy')
        allow(mock_ssh).to receive(:user).and_return('root')
        allow(mock_ssh).to receive(:execute)
        allow(mock_docker).to receive(:run)
        allow(client).to receive(:sleep)
      end

      it 'removes the existing container before creating a new one' do
        expect(mock_docker).to receive(:remove).with('odysseus-caddy').ordered
        expect(mock_docker).to receive(:run).ordered
        client.ensure_running
      end

      it 'returns true after recreating' do
        expect(client.ensure_running).to be true
      end
    end

    # Caddy's data directory follows the connecting user, exactly like every
    # other host path — see Odysseus::HostPaths#caddy_dir. The mkdir and the
    # volume mount have to name the same directory: if they disagree, `docker
    # run` mounts an empty directory over Caddy's real one and it starts with
    # no certificates, silently.
    describe "Caddy's data directory" do
      before do
        allow(mock_docker).to receive(:running?).with('odysseus-caddy').and_return(false, true)
        allow(mock_docker).to receive(:container_exists?).with('odysseus-caddy').and_return(false)
        allow(mock_docker).to receive(:run)
        allow(client).to receive(:sleep)
        allow(mock_ssh).to receive(:execute) # network creation, and echo $HOME unless overridden below
      end

      context 'for a root connection' do
        before { allow(mock_ssh).to receive(:user).and_return('root') }

        it 'mkdirs the historic system path, byte-identical to before this change' do
          expect(mock_ssh).to receive(:execute).with('mkdir -p /var/lib/odysseus/caddy')
          client.ensure_running
        end

        it 'mounts the historic system path, byte-identical to before this change' do
          expect(mock_docker).to receive(:run).with(
            hash_including(options: hash_including(volumes: ['/var/lib/odysseus/caddy:/data']))
          )
          client.ensure_running
        end
      end

      context 'for a non-root connection' do
        before do
          allow(mock_ssh).to receive(:user).and_return('deploy')
          allow(mock_ssh).to receive(:execute).with('echo $HOME').and_return("/home/deploy\n")
        end

        it 'mkdirs a directory under the connecting user\'s home' do
          expect(mock_ssh).to receive(:execute).with('mkdir -p /home/deploy/.odysseus/caddy')
          client.ensure_running
        end

        it 'mounts the same directory the mkdir created' do
          expect(mock_docker).to receive(:run).with(
            hash_including(options: hash_including(volumes: ['/home/deploy/.odysseus/caddy:/data']))
          )
          client.ensure_running
        end
      end

      context 'when the home directory needs shell escaping' do
        before do
          allow(mock_ssh).to receive(:user).and_return('deploy')
          allow(mock_ssh).to receive(:execute).with('echo $HOME').and_return("/home/deploy user\n")
        end

        it 'escapes the mkdir target' do
          expect(mock_ssh).to receive(:execute).with('mkdir -p /home/deploy\ user/.odysseus/caddy')
          client.ensure_running
        end

        it 'escapes the mounted directory the same way' do
          expect(mock_docker).to receive(:run).with(
            hash_including(options: hash_including(volumes: ['/home/deploy\ user/.odysseus/caddy:/data']))
          )
          client.ensure_running
        end
      end
    end
  end

  describe '#add_upstream' do
    context 'when route does not exist (ssl disabled)' do
      it 'creates new route at index 0' do
        # First call: GET routes returns empty array
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return('[]')
          .ordered

        # Second call: PUT to routes/0
        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(cmd).to include('-X PUT')
          expect(cmd).to include('/config/apps/http/servers/srv0/routes/0')
          expect(cmd).to include('myapp:3000')
          '{}'
        end.ordered

        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3000',
          ssl: false
        )
      end

      it 'includes healthcheck config when provided' do
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return('[]')
          .ordered

        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(cmd).to include('/health')
          '{}'
        end.ordered

        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3000',
          healthcheck: { path: '/health', interval: 10, timeout: 5 },
          ssl: false
        )
      end
    end

    context 'when route already exists (ssl disabled)' do
      let(:routes) do
        [{ '@id' => 'route-myapp', 'match' => [{ 'host' => ['app.example.com'] }],
           'handle' => [{ 'upstreams' => [{ 'dial' => 'myapp:3000' }] }] }]
      end

      it 'adds upstream to existing route' do
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return(routes.to_json)
          .ordered

        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(cmd).to include('-X PATCH')
          expect(cmd).to include('/upstreams')
          expect(cmd).to include('myapp:3001')
          '{}'
        end.ordered

        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3001',
          ssl: false
        )
      end

      it 'does not duplicate existing upstream' do
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return(routes.to_json)

        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3000',
          ssl: false
        )
      end

      it 'updates hosts when they have changed' do
        routes_with_hosts = [{
          '@id' => 'route-myapp',
          'match' => [{ 'host' => ['old.example.com'] }],
          'handle' => [{ 'upstreams' => [{ 'dial' => 'myapp:3000' }] }]
        }]

        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return(routes_with_hosts.to_json)
          .ordered

        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(cmd).to include('-X PATCH')
          expect(cmd).to include('/match/0/host')
          expect(cmd).to include('new.example.com')
          '{}'
        end.ordered

        client.add_upstream(
          service: 'myapp',
          hosts: ['new.example.com'],
          upstream: 'myapp:3000',
          ssl: false
        )
      end

      it 'does not patch hosts when they are unchanged' do
        routes_with_hosts = [{
          '@id' => 'route-myapp',
          'match' => [{ 'host' => ['app.example.com'] }],
          'handle' => [{ 'upstreams' => [{ 'dial' => 'myapp:3000' }] }]
        }]

        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return(routes_with_hosts.to_json)

        # Should NOT make any PATCH call for hosts
        expect(mock_ssh).not_to receive(:execute).with(%r{PATCH.*/match})

        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3000',
          ssl: false
        )
      end
    end

    context 'with ssl enabled' do
      it 'configures TLS automation before adding route' do
        # No tls app yet: Caddy answers a missing config path with an error or a
        # null body, never an empty object. An empty object would mean the key is
        # present, which calls for PATCH rather than PUT.
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/config/apps/tls})
          .and_return('null')

        # TLS config PUT
        expect(mock_ssh).to receive(:execute)
          .with(%r{PUT.*/config/apps/tls})
          .and_return('{}')

        # GET servers for ensure_https_server
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/servers})
          .and_return('{"srv0":{"listen":[":80",":443"]}}')

        # GET routes
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return('[]')

        # PUT route
        expect(mock_ssh).to receive(:execute)
          .with(%r{PUT.*/routes/0})
          .and_return('{}')

        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3000',
          ssl: true,
          ssl_email: 'admin@example.com'
        )
      end

      it 'merges new hosts with existing TLS subjects' do
        existing_tls = {
          'automation' => {
            'policies' => [{ 'subjects' => ['existing.example.com'] }]
          }
        }

        # GET existing TLS config
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/config/apps/tls})
          .and_return(existing_tls.to_json)

        # TLS config PUT - should include both domains
        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(cmd).to include('existing.example.com')
          expect(cmd).to include('new.example.com')
          '{}'
        end

        # GET servers for ensure_https_server
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/servers})
          .and_return('{"srv0":{"listen":[":80",":443"]}}')

        # GET routes
        expect(mock_ssh).to receive(:execute)
          .with(%r{GET.*/routes})
          .and_return('[]')

        # PUT route
        expect(mock_ssh).to receive(:execute)
          .with(%r{PUT.*/routes/0})
          .and_return('{}')

        client.add_upstream(
          service: 'myapp',
          hosts: ['new.example.com'],
          upstream: 'myapp:3000',
          ssl: true
        )
      end
    end
  end

  describe '#remove_upstream' do
    before do
      routes = [
        { '@id' => 'route-myapp', 'handle' => [{ 'upstreams' => [{ 'dial' => 'myapp:3000' }] }] }
      ]
      allow(mock_ssh).to receive(:execute).and_return(routes.to_json, '{}')
    end

    it 'removes route when last upstream' do
      expect(mock_ssh).to receive(:execute).with(/DELETE/).and_return('{}')
      client.remove_upstream(service: 'myapp', upstream: 'myapp:3000')
    end
  end

  describe '#config' do
    it 'fetches current config via API' do
      config = { 'apps' => { 'http' => {} } }
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('curl')
        expect(cmd).to include('/config/')
        config.to_json
      end

      result = client.config
      expect(result).to eq(config)
    end
  end

  describe '#list_services' do
    it 'returns parsed list of services' do
      routes = [
        {
          '@id' => 'route-myapp',
          'match' => [{ 'host' => ['app.example.com'] }],
          'handle' => [{
            'handler' => 'reverse_proxy',
            'upstreams' => [{ 'dial' => 'myapp:3000' }],
            'health_checks' => { 'active' => {} }
          }]
        },
        {
          '@id' => 'route-api',
          'match' => [{ 'host' => ['api.example.com'] }],
          'handle' => [{
            'handler' => 'reverse_proxy',
            'upstreams' => [{ 'dial' => 'api:8080' }]
          }]
        }
      ]

      expect(mock_ssh).to receive(:execute)
        .with(%r{GET.*/routes})
        .and_return(routes.to_json)

      result = client.list_services
      expect(result.size).to eq(2)
      expect(result[0]).to eq({
                                service: 'myapp',
                                hosts: ['app.example.com'],
                                upstreams: ['myapp:3000'],
                                has_healthcheck: true
                              })
      expect(result[1]).to eq({
                                service: 'api',
                                hosts: ['api.example.com'],
                                upstreams: ['api:8080'],
                                has_healthcheck: false
                              })
    end
  end

  describe '#tls_status' do
    it 'returns TLS configuration info' do
      tls_config = {
        'automation' => {
          'policies' => [{
            'subjects' => ['app.example.com', 'api.example.com'],
            'issuers' => [{ 'module' => 'acme', 'email' => 'admin@example.com' }]
          }]
        }
      }

      expect(mock_ssh).to receive(:execute)
        .with(%r{GET.*/config/apps/tls})
        .and_return(tls_config.to_json)

      result = client.tls_status
      expect(result[:enabled]).to be true
      expect(result[:policies].size).to eq(1)
      expect(result[:policies][0][:subjects]).to eq(['app.example.com', 'api.example.com'])
      expect(result[:policies][0][:issuer]).to eq('acme')
      expect(result[:policies][0][:email]).to eq('admin@example.com')
    end

    it 'returns disabled status when no TLS configured' do
      expect(mock_ssh).to receive(:execute)
        .with(%r{GET.*/config/apps/tls})
        .and_return('{}')

      result = client.tls_status
      expect(result[:enabled]).to be false
      expect(result[:policies]).to be_empty
    end
  end

  describe '#enable_tls_for_hosts' do
    def curl_response(body, status)
      "#{body}\n#{status}"
    end

    # Body of the -d payload for the command the block matched.
    def payload_of(cmd)
      JSON.parse(cmd[/-d '(.*?)' /m, 1])
    end

    before do
      # Already listening on 443, so ensure_https_server has nothing to patch.
      allow(mock_ssh).to receive(:execute)
        .with(%r{-X GET.*/config/apps/http/servers})
        .and_return(curl_response('{"srv0":{"listen":[":80",":443"]}}', 200))
    end

    context 'when Caddy has no tls app yet' do
      before do
        # Caddy answers 500 for a config path that does not exist.
        allow(mock_ssh).to receive(:execute)
          .with(%r{-X GET.*/config/apps/tls})
          .and_return(curl_response('{"error":"unknown object tls"}', 500))
      end

      it 'creates it' do
        expect(mock_ssh).to receive(:execute).with(/-X PUT/).and_return(curl_response('{}', 200))

        client.enable_tls_for_hosts(['app.example.com'], email: 'admin@example.com')
      end
    end

    context 'when the tls app already exists' do
      let(:existing_tls) do
        {
          'certificates' => { 'load_files' => [{ 'certificate' => '/certs/other.crt' }] },
          'automation' => {
            'on_demand' => { 'rate_limit' => { 'interval' => '2m' } },
            'policies' => [
              { 'subjects' => ['other.example.com'], 'issuers' => [{ 'module' => 'acme' }] }
            ]
          }
        }
      end

      before do
        allow(mock_ssh).to receive(:execute)
          .with(%r{-X GET.*/config/apps/tls})
          .and_return(curl_response(existing_tls.to_json, 200))

        # Caddy's PUT is create-only: it answers 409 when the key is already there.
        allow(mock_ssh).to receive(:execute)
          .with(/-X PUT/)
          .and_return(curl_response('{"error":"[/config/apps/tls] key already exists: tls"}', 409))
      end

      it 'updates the config in place rather than failing with 409' do
        expect(mock_ssh).to receive(:execute).with(/-X PATCH/).and_return(curl_response('{}', 200))

        expect { client.enable_tls_for_hosts(['app.example.com'], email: 'admin@example.com') }
          .not_to raise_error
      end

      it 'keeps subjects that were already covered' do
        expect(mock_ssh).to receive(:execute).with(/-X PATCH/) do |cmd|
          subjects = payload_of(cmd).dig('automation', 'policies', 0, 'subjects')
          expect(subjects).to contain_exactly('other.example.com', 'app.example.com')
          curl_response('{}', 200)
        end

        client.enable_tls_for_hosts(['app.example.com'], email: 'admin@example.com')
      end

      it 'leaves sibling tls configuration alone' do
        expect(mock_ssh).to receive(:execute).with(/-X PATCH/) do |cmd|
          written = payload_of(cmd)
          expect(written['certificates']).to eq(existing_tls['certificates'])
          expect(written.dig('automation', 'on_demand')).to eq(existing_tls.dig('automation', 'on_demand'))
          curl_response('{}', 200)
        end

        client.enable_tls_for_hosts(['app.example.com'], email: 'admin@example.com')
      end
    end
  end

  describe 'admin API error handling' do
    # curl's write-out variable is %{http_code}. It looks like a Ruby format
    # token, and a tool that rewrites it to %<http_code>s leaves curl emitting
    # the literal text — split_status then finds no status and every failed
    # write looks like a success again.
    it "asks curl for the status code in curl's own syntax" do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include("-w '\\n%{http_code}'")
        "[]\n200"
      end

      client.list_services
    end

    # curl is invoked with -w '\n%{http_code}', so a real response is the body
    # followed by the status code on its own line.
    def curl_response(body, status)
      "#{body}\n#{status}"
    end

    it 'raises ProxyApiError when a write is rejected' do
      allow(mock_ssh).to receive(:execute)
        .with(%r{GET.*/routes})
        .and_return(curl_response('[]', 200))
      allow(mock_ssh).to receive(:execute)
        .with(/-X PUT/)
        .and_return(curl_response('{"error":"loading new config: invalid upstream"}', 400))

      expect do
        client.add_upstream(
          service: 'myapp',
          hosts: ['app.example.com'],
          upstream: 'myapp:3000',
          ssl: false
        )
      end.to raise_error(Odysseus::ProxyApiError) { |error|
        expect(error.message).to include('400')
        expect(error.message).to include('invalid upstream')
      }
    end

    it 'raises ProxyApiError when a route delete is rejected' do
      routes = [{ '@id' => 'route-myapp', 'handle' => [{ 'upstreams' => [{ 'dial' => 'myapp:3000' }] }] }]
      allow(mock_ssh).to receive(:execute)
        .with(%r{GET.*/routes})
        .and_return(curl_response(routes.to_json, 200))
      allow(mock_ssh).to receive(:execute)
        .with(/-X DELETE/)
        .and_return(curl_response('{"error":"unknown object"}', 500))

      expect { client.remove_upstream(service: 'myapp', upstream: nil) }
        .to raise_error(Odysseus::ProxyApiError, /500/)
    end

    it 'treats a failed GET as absent config so callers can fall back' do
      # A freshly booted Caddy has no tls app; the admin API answers 500.
      allow(mock_ssh).to receive(:execute)
        .with(%r{GET.*/config/apps/tls})
        .and_return(curl_response('{"error":"unknown object tls"}', 500))

      result = client.tls_status
      expect(result[:enabled]).to be false
      expect(result[:policies]).to be_empty
    end

    it 'parses a successful response without treating the status code as body' do
      allow(mock_ssh).to receive(:execute)
        .with(%r{GET.*/servers})
        .and_return(curl_response('{"srv0":{"listen":[":80"]}}', 200))

      expect(client.listen_addresses).to eq([':80'])
    end
  end

  describe '#status' do
    it 'returns combined status summary' do
      allow(mock_docker).to receive(:running?).with('odysseus-caddy').and_return(true)

      # listen_addresses
      expect(mock_ssh).to receive(:execute)
        .with(%r{GET.*/servers})
        .and_return('{"srv0":{"listen":[":80",":443"]}}')

      # list_services
      expect(mock_ssh).to receive(:execute)
        .with(%r{GET.*/routes})
        .and_return('[]')

      # tls_status
      expect(mock_ssh).to receive(:execute)
        .with(%r{GET.*/config/apps/tls})
        .and_return('{}')

      result = client.status
      expect(result[:running]).to be true
      expect(result[:listen]).to eq([':80', ':443'])
      expect(result[:services]).to eq([])
      expect(result[:tls][:enabled]).to be false
    end
  end
end
