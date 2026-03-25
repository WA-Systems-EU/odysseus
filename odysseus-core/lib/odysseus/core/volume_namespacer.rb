# lib/odysseus/core/volume_namespacer.rb

module Odysseus
  module Core
    module VolumeNamespacer
      # Namespace volumes to avoid conflicts when multiple apps share a server.
      #
      # Named volumes (no leading /) get prefixed with the service name:
      #   "data:/var/lib/postgresql/data" → "myapp-data:/var/lib/postgresql/data"
      #
      # Host path volumes (leading /) are left as-is — the user owns the path.
      #
      # When a named volume is being namespaced, we check if the old (un-namespaced)
      # volume already exists on the server. If it does, we reuse it to avoid data loss
      # and log a deprecation warning.
      #
      # @param volumes [Array<String>, nil] volume specs (e.g. ["data:/container/path"])
      # @param service [String] service name used as prefix
      # @return [Array<String>, nil] namespaced volume specs
      def namespace_volumes(volumes, service:)
        return nil unless volumes

        volumes.map { |v| namespace_volume(v, service: service) }
      end

      private

      def namespace_volume(volume_spec, service:)
        host_part, container_part, mode = volume_spec.split(':')

        # Host path mount (absolute path) — user controls the path, leave as-is
        return volume_spec if host_part.start_with?('/')

        # Already namespaced — don't double-prefix
        return volume_spec if host_part.start_with?("#{service}-")

        namespaced = "#{service}-#{host_part}"

        # Check if we need to handle migration from old volume name
        if docker_volume_exists?(namespaced)
          # New namespaced volume already exists — use it
          return build_volume_spec(namespaced, container_part, mode)
        end

        if docker_volume_exists?(host_part)
          # Old un-namespaced volume exists but new one doesn't.
          # Reuse the old volume to avoid data loss, and warn the user.
          log "Volume '#{host_part}' exists but is not namespaced. Reusing it to avoid data loss.", :warn
          log "  To migrate, run: docker volume create #{namespaced} && " \
              "docker run --rm -v #{host_part}:/from -v #{namespaced}:/to alpine sh -c 'cp -a /from/. /to/'", :warn
          return volume_spec
        end

        # Neither exists — use the new namespaced name (fresh deploy)
        build_volume_spec(namespaced, container_part, mode)
      end

      def build_volume_spec(host_part, container_part, mode)
        parts = [host_part, container_part]
        parts << mode if mode
        parts.join(':')
      end

      def docker_volume_exists?(name)
        return false unless respond_to?(:docker_client, true)

        docker_client.volume_exists?(name)
      rescue StandardError
        false
      end

      def docker_client
        @docker
      end
    end
  end
end
