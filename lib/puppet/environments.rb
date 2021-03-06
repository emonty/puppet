# @api private
module Puppet::Environments

  class EnvironmentNotFound < Puppet::Error
    def initialize(environment_name, original = nil)
      environmentpath = Puppet[:environmentpath]
      super("Could not find a directory environment named '#{environment_name}' anywhere in the path: #{environmentpath}. Does the directory exist?", original)
    end
  end

  # @api private
  module EnvironmentCreator
    # Create an anonymous environment.
    #
    # @param module_path [String] A list of module directories separated by the
    #   PATH_SEPARATOR
    # @param manifest [String] The path to the manifest
    # @return A new environment with the `name` `:anonymous`
    #
    # @api private
    def for(module_path, manifest)
      Puppet::Node::Environment.create(:anonymous,
                                       module_path.split(File::PATH_SEPARATOR),
                                       manifest)
    end
  end

  # Provide any common methods that loaders should have. It requires that any
  # classes that include this module implement get
  # @api private
  module EnvironmentLoader
    # @!macro loader_get_or_fail
    def get!(name)
      environment = get(name)
      if environment
        environment
      else
        raise EnvironmentNotFound, name
      end
    end
  end

  # @!macro [new] loader_search_paths
  #   A list of indicators of where the loader is getting its environments from.
  #   @return [Array<String>] The URIs of the load locations
  #
  # @!macro [new] loader_list
  #   @return [Array<Puppet::Node::Environment>] All of the environments known
  #     to the loader
  #
  # @!macro [new] loader_get
  #   Find a named environment
  #
  #   @param name [String,Symbol] The name of environment to find
  #   @return [Puppet::Node::Environment, nil] the requested environment or nil
  #     if it wasn't found
  #
  # @!macro [new] loader_get_conf
  #   Attempt to obtain the initial configuration for the environment.  Not all
  #   loaders can provide this.
  #
  #   @param name [String,Symbol] The name of the environment whose configuration
  #     we are looking up
  #   @return [Puppet::Setting::EnvironmentConf, nil] the configuration for the
  #     requested environment, or nil if not found or no configuration is available
  #
  # @!macro [new] loader_get_or_fail
  #   Find a named environment or raise
  #   Puppet::Environments::EnvironmentNotFound when the named environment is
  #   does not exist.
  #
  #   @param name [String,Symbol] The name of environment to find
  #   @return [Puppet::Node::Environment] the requested environment

  # A source of pre-defined environments.
  #
  # @api private
  class Static
    include EnvironmentCreator
    include EnvironmentLoader

    def initialize(*environments)
      @environments = environments
    end

    # @!macro loader_search_paths
    def search_paths
      ["data:text/plain,internal"]
    end

    # @!macro loader_list
    def list
      @environments
    end

    # @!macro loader_get
    def get(name)
      @environments.find do |env|
        env.name == name.intern
      end
    end

    # Returns a basic environment configuration object tied to the environment's
    # implementation values.  Will not interpolate.
    #
    # @!macro loader_get_conf
    def get_conf(name)
      env = get(name)
      if env
        Puppet::Settings::EnvironmentConf.static_for(env)
      else
        nil
      end
    end
  end

  # A source of unlisted pre-defined environments.
  #
  # Used only for internal bootstrapping environments which are not relevant
  # to an end user (such as the fall back 'configured' environment).
  #
  # @api private
  class StaticPrivate < Static

    # Unlisted
    #
    # @!macro loader_list
    def list
      []
    end
  end

  # Reads environments from a directory on disk. Each environment is
  # represented as a sub-directory. The environment's manifest setting is the
  # `manifest` directory of the environment directory. The environment's
  # modulepath setting is the global modulepath (from the `[master]` section
  # for the master) prepended with the `modules` directory of the environment
  # directory.
  #
  # @api private
  class Directories
    include EnvironmentLoader

    def initialize(environment_dir, global_module_path)
      @environment_dir = environment_dir
      @global_module_path = global_module_path
    end

    # Generate an array of directory loaders from a path string.
    # @param path [String] path to environment directories
    # @param global_module_path [Array<String>] the global modulepath setting
    # @return [Array<Puppet::Environments::Directories>] An array
    #   of configured directory loaders.
    def self.from_path(path, global_module_path)
      environments = path.split(File::PATH_SEPARATOR)
      environments.map do |dir|
        Puppet::Environments::Directories.new(dir, global_module_path)
      end
    end

    # @!macro loader_search_paths
    def search_paths
      ["file://#{@environment_dir}"]
    end

    # @!macro loader_list
    def list
      valid_directories.collect do |envdir|
        name = Puppet::FileSystem.basename_string(envdir).intern

        create_environment(name)
      end
    end

    # @!macro loader_get
    def get(name)
      if valid_directory?(File.join(@environment_dir, name.to_s))
        create_environment(name)
      end
    end

    # @!macro loader_get_conf
    def get_conf(name)
      envdir = File.join(@environment_dir, name.to_s)
      if valid_directory?(envdir)
        return Puppet::Settings::EnvironmentConf.load_from(envdir, @global_module_path)
      end
      nil
    end

    private

    def create_environment(name, setting_values = nil)
      env_symbol = name.intern
      setting_values = Puppet.settings.values(env_symbol, Puppet.settings.preferred_run_mode)
      Puppet::Node::Environment.create(
        env_symbol,
        Puppet::Node::Environment.split_path(setting_values.interpolate(:modulepath)),
        setting_values.interpolate(:manifest),
        setting_values.interpolate(:config_version)
      )
    end

    def valid_directory?(envdir)
      name = Puppet::FileSystem.basename_string(envdir)
      Puppet::FileSystem.directory?(envdir) &&
         Puppet::Node::Environment.valid_name?(name)
    end

    def valid_directories
      if Puppet::FileSystem.directory?(@environment_dir)
        Puppet::FileSystem.children(@environment_dir).select do |child|
          valid_directory?(child)
        end
      else
        []
      end
    end
  end

  # Combine together multiple loaders to act as one.
  # @api private
  class Combined
    include EnvironmentLoader

    def initialize(*loaders)
      @loaders = loaders
    end

    # @!macro loader_search_paths
    def search_paths
      @loaders.collect(&:search_paths).flatten
    end

    # @!macro loader_list
    def list
      @loaders.collect(&:list).flatten
    end

    # @!macro loader_get
    def get(name)
      @loaders.each do |loader|
        if env = loader.get(name)
          return env
        end
      end
      nil
    end

    # @!macro loader_get_conf
    def get_conf(name)
      @loaders.each do |loader|
        if conf = loader.get_conf(name)
          return conf
        end
      end
      nil
    end

  end

  class Cached
    include EnvironmentLoader

    class DefaultCacheExpirationService
      def created(env)
      end

      def expired?(env_name)
        false
      end

      def evicted(env_name)
      end
    end

    def self.cache_expiration_service=(service)
      @cache_expiration_service = service
    end

    def self.cache_expiration_service
      @cache_expiration_service || DefaultCacheExpirationService.new
    end

    def initialize(loader)
      @loader = loader
      @cache = {}
      @cache_expiration_service = Puppet::Environments::Cached.cache_expiration_service
    end

    # @!macro loader_list
    def list
      @loader.list
    end

    # @!macro loader_search_paths
    def search_paths
      @loader.search_paths
    end

    # @!macro loader_get
    def get(name)
      evict_if_expired(name)
      if result = @cache[name]
        return result.value
      elsif (result = @loader.get(name))
        @cache[name] = entry(result)
        result
      end
    end

    # Clears the cache of the environment with the given name.
    # (The intention is that this could be used from a MANUAL cache eviction command (TBD)
    def clear(name)
      @cache.delete(name)
    end

    # Clears all cached environments.
    # (The intention is that this could be used from a MANUAL cache eviction command (TBD)
    def clear_all()
      @cache = {}
    end

    # This implementation evicts the cache, and always gets the current
    # configuration of the environment
    #
    # TODO: While this is wasteful since it
    # needs to go on a search for the conf, it is too disruptive to optimize
    # this.
    #
    # @!macro loader_get_conf
    def get_conf(name)
      evict_if_expired(name)
      @loader.get_conf(name)
    end

    # Creates a suitable cache entry given the time to live for one environment
    #
    def entry(env)
      @cache_expiration_service.created(env)
      ttl = (conf = get_conf(env.name)) ? conf.environment_timeout : Puppet.settings.value(:environment_timeout)
      Puppet.debug {"Caching environment '#{env.name}' (cache ttl: #{ttl})"}
      case ttl
      when 0
        NotCachedEntry.new(env)     # Entry that is always expired (avoids syscall to get time)
      when Float::INFINITY
        Entry.new(env)              # Entry that never expires (avoids syscall to get time)
      else
        TTLEntry.new(env, ttl)
      end
    end

    # Evicts the entry if it has expired
    # Also clears caches in Settings that may prevent the entry from being updated
    def evict_if_expired(name)
      if (result = @cache[name]) && (result.expired? || @cache_expiration_service.expired?(name))
      Puppet.debug {"Evicting cache entry for environment '#{name}'"}
        @cache.delete(name)
        @cache_expiration_service.evicted(name)

        Puppet.settings.clear_environment_settings(name)
      end
    end

    # Never evicting entry
    class Entry
      attr_reader :value

      def initialize(value)
        @value = value
      end

      def expired?
        false
      end
    end

    # Always evicting entry
    class NotCachedEntry < Entry
      def expired?
        true
      end
    end

    # Time to Live eviction policy entry
    class TTLEntry < Entry
      def initialize(value, ttl_seconds)
        super value
        @ttl = Time.now + ttl_seconds
      end

      def expired?
        Time.now > @ttl
      end
    end
  end
end
