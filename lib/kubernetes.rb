require 'tempfile'
module CivoCLI
  class Kubernetes < Thor
    desc "list", "list all kubernetes clusters"
    option :quiet, type: :boolean, aliases: '-q'
    def list
      CivoCLI::Config.set_api_auth
      if options[:quiet]
        Civo::Kubernetes.all.items.each do |cluster|
        puts cluster.id
        end
      else
        rows = []
        Civo::Kubernetes.all.items.each do |cluster|
          rows << [cluster.id, cluster.name, cluster.num_target_nodes, cluster.target_nodes_size, cluster.status]
        end
        puts Terminal::Table.new headings: ['ID', 'Name', '# Nodes', 'Size', 'Status'], rows: rows
      end
    rescue Flexirest::HTTPForbiddenClientException
      reject_user_access
    end
    map "ls" => "list", "all" => "list"

    desc "show ID/NAME", "show a Kubernetes cluster by ID or name"
    def show(id)
      CivoCLI::Config.set_api_auth
      rows = []
      cluster = Finder.detect_cluster(id)

      puts "                ID : #{cluster.id}"
      puts "              Name : #{cluster.name}"
      puts "           # Nodes : #{cluster.num_target_nodes}"
      puts "              Size : #{cluster.target_nodes_size}"
      case cluster.status
      when "ACTIVE"
        puts "            Status : #{cluster.status.colorize(:green)}"
      when /ING$/
        puts "            Status : #{cluster.status.colorize(:orange)}"
      else
        puts "            Status : #{cluster.status.colorize(:red)}"
      end
      puts "           Version : #{cluster.kubernetes_version}"
      puts "      API Endpoint : #{cluster.api_endpoint}"

      puts ""
      puts "Nodes:"
      rows = []
      cluster.instances.each do |instance|
        rows << [instance.hostname, instance.public_ip, instance.status]
      end
      puts Terminal::Table.new headings: ['Name', 'IP', 'Status'], rows: rows

      if cluster.installed_applications.any?
        puts ""
        puts "Installed marketplace applications:"
        rows = []
        cluster.installed_applications.each do |application|
          name = application.application
          if application.plan
            name += " #{application.plan}"
          end
          installed = application.installed ? "Yes" : "Not yet"
          rows << [name, application.version, installed, application.category]
        end
        puts Terminal::Table.new headings: ['Name', 'Version', 'Installed', 'Category'], rows: rows
      end
    rescue Flexirest::HTTPException => e
      puts e.result.reason.colorize(:red)
      exit 1
    end
    map "get" => "show", "inspect" => "show"


    desc "config ID/NAME [--save]", "get or save the ~/.kube/config for a Kubernetes cluster by ID or name"
    option :save, type: :boolean, aliases: ['--export', '-s']
    long_desc <<-LONGDESC
      Gets the configuration information for a Kubernetes cluster by ID or name.
      \x5Use optional parameter --save [-s or --export] to merge the fetched configuration
      \x5into your Kubernetes configuration file at ~/.kube/config.
      \x5Please note that this option requires you to have `kubectl` installed.
    LONGDESC
    def config(id)
      CivoCLI::Config.set_api_auth
      cluster = Finder.detect_cluster(id)

      if !cluster.ready
        puts "The cluster isn't ready yet, so the KUBECONFIG isn't available.".colorize(:red)
        exit 1
      elsif cluster.kubeconfig.blank?
        puts "The cluster is being installed, but the KUBECONFIG isn't available yet.".colorize(:red)
        exit 1
      else
        if options[:save]
          save_config(cluster)
        else
          puts cluster.kubeconfig
        end
      end
    rescue Flexirest::HTTPException => e
      puts e.result.reason.colorize(:red)
      exit 1
    end
    map "kubeconfig" => "config"

    desc "create [NAME] [...]", "create a new kubernetes cluster with the specified name and provided options"
    option :size, default: 'g2.medium', banner: 'size'
    option :nodes, default: '3', banner: 'node_count'
    option :wait, type: :boolean, banner: 'wait until cluster is running'
    option :save, type: :boolean
    option :switch, type: :boolean
    option :applications, type: :string, aliases: %w{apps app application}
    long_desc <<-LONGDESC
      Create a new Kubernetes cluster with name (randomly assigned if blank), instance size (default: g2.medium),
      \x5\x5Optional parameters are as follows:
      \x5 --size=<instance_size> - 'g2.medium' if blank. List of sizes and codes to use can be found through `civo sizes`
      \x5 --nodes=<count> - '3' if blank
      \x5 --applications=name1,name2 - optional, use names shown by running `civo applications`
      \x5 --wait - wait for build to complete and show status. Off by default.
      \x5 --save - save resulting configuration to ~/.kube/config (requires kubectl and the --wait option)
      \x5 --switch - switch context to newly-created cluster (requires kubectl and the --wait and --save options, as well as existing kubeconfig file)
    LONGDESC
    def create(name = CivoCLI::NameGenerator.create)
      CivoCLI::Config.set_api_auth

      applications = []
      (options[:applications] || "").split(",").map(&:chomp).each do |name|
        name, plan = name.split(":")
        app = Finder.detect_app(name)
        if app.default # Will be installed by default
          next
        end

        plans = app.plans&.items

        if app && plans.present? && plan.blank?
          if AskService.available?
            plan = AskService.choose("You requested to add #{app.name} but didn't select a plan. Please choose one...", plans.map(&:label))
            if plan.present?
              puts "Thank you, next time you could use \"#{app.name}:#{plan}\" to choose automatically"
            end
          else
            puts "You need to specify a plan".colorize(:red) + " from those available (#{plans.join(", ")} using the syntax \"#{app.name}:plan\""
            exit 1
          end
        end

        if plan.present?
          applications << "#{app.name}:#{plan}"
        else
          applications << app.name
        end
      end

      @cluster = Civo::Kubernetes.create(name: name, target_nodes_size: options[:size], num_target_nodes: options[:nodes], applications: applications.join(","))

      if options[:wait]
        timer = CivoCLI::Timer.new
        timer.start_timer
        print "Building new Kubernetes cluster #{name.colorize(:green)}: "

        spinner = CivoCLI::Spinner.spin(instance: @instance) do |s|
          Civo::Kubernetes.all.items.each do |cluster|
            if cluster.id == @cluster.id && cluster.ready
              s[:final_cluster] = cluster
            end
          end
          s[:final_cluster]
        end

        timer.end_timer
        puts "\b Done\nCreated Kubernetes cluster #{name.colorize(:green)} in #{Time.at(timer.time_elapsed).utc.strftime("%M min %S sec")}"
      elsif !options[:wait] && options[:save]
        puts "Creating Kubernetes cluster #{name.colorize(:green)}. Can only save configuration once cluster is created."
      else
        puts "Created Kubernetes cluster #{name.colorize(:green)}."
      end

      if options[:save] && options[:wait]
        save_config(spinner.final_cluster)
      end
    rescue Flexirest::HTTPException => e
      puts e.result.reason.colorize(:red)
      exit 1
    end

    desc "rename ID/NAME [--name]", "rename Kubernetes cluster"
    option :name
    long_desc <<-LONGDESC
      Use --name=new_host_name to specify the new name you wish to use.
    LONGDESC
    def rename(id)
      CivoCLI::Config.set_api_auth
      cluster = Finder.detect_cluster(id)

      if options[:name]
        Civo::Kubernetes.update(id: cluster.id, name: options[:name])
        puts "Kubernetes cluster #{cluster.id} is now named #{options[:name].colorize(:green)}"
      end
    rescue Flexirest::HTTPException => e
      puts e.result.reason.colorize(:red)
      exit 1
    end

    desc "scale ID/NAME [--nodes]", "rescale the Kubernetes cluster to a new node count"
    option :nodes
    long_desc <<-LONGDESC
      Use --nodes=count to specify the new number of nodes to run.
    LONGDESC
    def scale(id)
      CivoCLI::Config.set_api_auth
      cluster = Finder.detect_cluster(id)

      if options[:nodes]
        Civo::Kubernetes.update(id: cluster.id, num_target_nodes: options[:nodes])
        puts "Kubernetes cluster #{cluster.name.colorize(:green)} will now have #{options[:nodes].colorize(:green)} nodes"
      end
    rescue Flexirest::HTTPException => e
      puts e.result.reason.colorize(:red)
      exit 1
    end
    map "rescale" => "scale"

    desc "remove ID/NAME", "removes an entire Kubernetes cluster with ID/name entered (use with caution!)"
    def remove(id)
      CivoCLI::Config.set_api_auth
      cluster = Finder.detect_cluster(id)

      puts "Removing Kubernetes cluster #{cluster.name.colorize(:red)}"
      cluster.remove
    rescue Flexirest::HTTPException => e
      puts e.result.reason.colorize(:red)
      exit 1
    end
    map "delete" => "remove", "destroy" => "remove", "rm" => "remove"

    default_task :help

    private

    def save_config(cluster)
      config_file_exists = File.exist?("#{ENV["HOME"]}/.kube/config")
      tempfile = Tempfile.new('import_kubeconfig')
      begin
        tempfile.write(cluster.kubeconfig)
        tempfile.size
        if options[:switch]
          result = `KUBECONFIG=#{tempfile.path}:~/.kube/config kubectl config view --flatten`
        else
          result = `KUBECONFIG=~/.kube/config:#{tempfile.path} kubectl config view --flatten`
        end
        Dir.mkdir("#{ENV['HOME']}/.kube/") unless Dir.exist?("#{ENV["HOME"]}/.kube/")
        File.write("#{ENV['HOME']}/.kube/config", result)
        if config_file_exists && options[:switch]
          puts "Merged".colorize(:green) + " config into ~/.kube/config and switched context to #{cluster.name}"
        elsif config_file_exists && !options[:switch]
          puts "Merged".colorize(:green) + " config into ~/.kube/config"
        else
          puts "Saved".colorize(:green) + " config to ~/.kube/config"
        end
      ensure
        tempfile.close
        tempfile.unlink
      end
    end

    def reject_user_access
      puts "Sorry, this functionality is currently in closed beta and not available to the public yet"
      exit(1)
    end
  end
end
