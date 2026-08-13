# odysseus-cli/lib/odysseus/cli/rollback_commands.rb
#
# `odysseus rollback [VERSION]` and `odysseus rollback --list`.
# Split out of CLI so the command surface for rollback lives together and
# CLI itself stays under the project's class-length budget.

module Odysseus
  module CLI
    module RollbackCommands
      # Rollback command
      def rollback(options = {})
        config_file = options[:config] || 'deploy.yml'
        verbose = options[:verbose] || @ui.debug?

        config = load_config(config_file)
        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)

        return rollback_list(executor, config) if options[:list]

        plan = @ui.spin_step('Checking what every host can run') do
          executor.rollback_plan(version: options[:version])
        end

        @ui.blank
        @ui.info 'Service', config[:service]
        @ui.info 'Rolling back to', "#{config[:image]}:#{plan.version}"
        @ui.info 'Commit', plan.ref if plan.ref
        @ui.warn rollback_approximate_warning(options[:version]) if plan.approximate
        @ui.blank

        start_time = Time.now

        @ui.stream_steps(title: 'Rolling back service') do
          executor.rollback_all(plan)
        end

        @ui.deploy_complete(duration: (Time.now - start_time).round(1))
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      private

      # rollback --list: what each host has, without changing anything.
      # Reads only the hosts, so it works without a git repository.
      def rollback_list(executor, config)
        survey = @ui.spin_step('Reading versions from hosts') { executor.version_survey }

        @ui.blank
        @ui.info 'Service', config[:service]
        @ui.blank

        survey.each do |host_versions|
          @ui.section host_versions.host
          @ui.info 'Serving', host_versions.current || '(nothing running)'

          rows = rollback_rows(host_versions)
          if rows.empty?
            @ui.step '(no deploy history on this host)'
          else
            @ui.table(headers: %w[Version Deployed Ref Deployer Image], rows: rows)
          end
          @ui.blank
        end
      end

      # One row per distinct version, most recently deployed first. A version
      # deployed repeatedly is reported once, at its latest deploy time.
      def rollback_rows(host_versions)
        latest = {}
        host_versions.history.each { |e| latest[e.version] = e }

        latest.values.reverse.map do |e|
          [e.version, e.at, e.ref, e.deployer,
           host_versions.available?(e.version) ? 'present' : 'missing']
        end
      end

      # `approximate` on a RollbackPlan means only "no host had a deploy log" —
      # not that the requested version itself is uncertain. When the operator
      # named a version explicitly, no ordering was inferred at all, so it
      # would be misleading to call the ordering approximate; there is simply
      # no record of what has run here.
      def rollback_approximate_warning(requested_version)
        if requested_version
          'No host has a deploy log for this service, so there is no record of what has been ' \
            'deployed here'
        else
          'No host has a deploy log, so the previous version came from image creation time ' \
            'and the ordering is approximate'
        end
      end
    end
  end
end
