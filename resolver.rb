# encoding: utf-8

# frozen_string_literal: true

# import re

# from ruamel.yaml.compat import _DEFAULT_YAML_VERSION, _F  # NOQA
# from ruamel.yaml.error import *  # NOQA
# from ruamel.yaml.nodes import MappingNode, ScalarNode, SequenceNode  # NOQA
# from ruamel.yaml.util import RegExp  # NOQA

require_relative './compat'
require_relative './error'
require_relative './nodes'
require_relative './util'

module SweetStreetYaml
  # resolvers consist of
  # - a list of applicable version
  # - a tag
  # - a regexp
  # - a list of first characters to match
  IMPLICIT_RESOLVERS = [
    [[VERSION_1_2],
      'tag:yaml.org,2002:bool',
      Regexp.new("'^(?:true|True|TRUE|false|False|FALSE)$'", Regexp::EXTENDED),
      SweetStreetYaml::Util.list('tTfF')],
    [[VERSION_1_1],
      'tag:yaml.org,2002:bool',
      Regexp.new("'^^(?:y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$'", Regexp::EXTENDED),
      SweetStreetYaml::Util.list('yYnNtTfFoO')],
    [[VERSION_1_2],
      'tag:yaml.org,2002:float',
      Regexp.new("'^(?:
         [-+]?(?:[0-9][0-9_]*)\\.[0-9_]*(?:[eE][-+]?[0-9]+)?
        |[-+]?(?:[0-9][0-9_]*)(?:[eE][-+]?[0-9]+)
        |[-+]?\\.[0-9_]+(?:[eE][-+][0-9]+)?
        |[-+]?\\.(?:inf|Inf|INF)
        |\\.(?:nan|NaN|NAN))$'", Regexp::EXTENDED),
      SweetStreetYaml::Util.list('-+0123456789.')],
    [[VERSION_1_1],
      'tag:yaml.org,2002:float',
      Regexp.new("'^(?:
         [-+]?(?:[0-9][0-9_]*)\\.[0-9_]*(?:[eE][-+]?[0-9]+)?
        |[-+]?(?:[0-9][0-9_]*)(?:[eE][-+]?[0-9]+)
        |\\.[0-9_]+(?:[eE][-+][0-9]+)?
        |[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\\.[0-9_]*  # sexagesimal float
        |[-+]?\\.(?:inf|Inf|INF)
        |\\.(?:nan|NaN|NAN))$'", Regexp::EXTENDED),
      SweetStreetYaml::Util.list('-+0123456789.')],
    [[VERSION_1_2],
      'tag:yaml.org,2002:int',
      Regexp.new("'^(?:[-+]?0b[0-1_]+
        |[-+]?0o?[0-7_]+
        |[-+]?[0-9_]+
        |[-+]?0x[0-9a-fA-F_]+)$'", Regexp::EXTENDED),
      SweetStreetYaml::Util.list('-+0123456789')],
    [[VERSION_1_1],
      'tag:yaml.org,2002:int',
      Regexp.new("'^(?:[-+]?0b[0-1_]+
        |[-+]?0?[0-7_]+
        |[-+]?(?:0|[1-9][0-9_]*)
        |[-+]?0x[0-9a-fA-F_]+
        |[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)$'", Regexp::EXTENDED),  # sexagesimal int
      SweetStreetYaml::Util.list('-+0123456789')],
    [[VERSION_1_2, VERSION_1_1],
      'tag:yaml.org,2002:merge',
      Regexp.new('^[?:<<]$'),
      ['<']],
    [[VERSION_1_2, VERSION_1_1],
      'tag:yaml.org,2002:null',
      Regexp.new("'^(?: ~
        |null|Null|NULL
        | )$'", Regexp::EXTENDED),
      ['~', 'n', 'N', '']],
    [[VERSION_1_2, VERSION_1_1],
      'tag:yaml.org,2002:timestamp',
      Regexp.new("'^(?:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]
        |[0-9][0-9][0-9][0-9] -[0-9][0-9]? -[0-9][0-9]?
        (?:[Tt]|[ \\t]+)[0-9][0-9]?
        :[0-9][0-9] :[0-9][0-9] (?:\\.[0-9]*)?
        (?:[ \\t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?)$'", Regexp::EXTENDED),
      SweetStreetYaml::Util.list('0123456789')],
    [[VERSION_1_2, VERSION_1_1],
      'tag:yaml.org,2002:value',
      Regexp.new('^(?:=)$'),
      ['=']],
    # The following resolver is only for documentation purposes. It cannot work
    # because plain scalars cannot start with '!', '&', || '*'.
    [[VERSION_1_2, VERSION_1_1],
      'tag:yaml.org,2002:yaml',
      Regexp.new('^(?:!|&|\\*)$'),
      SweetStreetYaml::Util.list('!&*')]
  ].freeze


  class ResolverError < YAMLError
  end


  class BaseResolver
    DEFAULT_SCALAR_TAG = 'tag:yaml.org,2002:str'
    DEFAULT_SEQUENCE_TAG = 'tag:yaml.org,2002:seq'
    DEFAULT_MAPPING_TAG = 'tag:yaml.org,2002:map'

    class << self
      attr_accessor :yaml_implicit_resolvers
      attr_accessor :yaml_path_resolvers
    end
    @yaml_implicit_resolvers = {}
    @yaml_path_resolvers = {}

    def initialize(loadumper = nil)
      @loadumper = loadumper
      @loadumper._resolver ||= loadumper
      @_loader_version = nil
      @resolver_exact_paths = []
      @resolver_prefix_paths = []
    end

    def parser
      if @loadumper
        return loadumper.parser if @loadumper&.typ

        return loadumper._parser
      end

      nil
    end

    def self.add_implicit_resolver_base(tag, regexp, first)
      if yaml_implicit_resolvers.nil?
        yaml_implicit_resolvers ||= {}
        yaml_implicit_resolvers.each { |k, v| yaml_implicit_resolvers[k] = [k, v] }
      end
      first = [nil] unless first
      first.each do |ch|
        yaml_implicit_resolvers.fetch(ch) do |ch|
          yaml_implicit_resolvers[ch] ||= []
          yaml_implicit_resolvers[ch].append([tag, regexp])
        end
      end
    end

    def self.add_implicit_resolver(tag, regexp, first)
      add_implicit_resolver_base(tag, regexp, first)
      IMPLICIT_RESOLVERS.append([[[1, 2], [1, 1]], tag, regexp, first])
    end

=begin
    def self.add_path_resolver(tag, path, kind: nil)
        # Note: `add_path_resolver` is experimental.  The API could be changed.
        # `new_path` is a pattern that is matched against the path from the
        # root to the node that is being considered.  `node_path` elements are
        # tuples `(node_check, index_check)`.  `node_check` is a node class
        # `ScalarNode`, `SequenceNode`, `MappingNode` || `nil`.  `nil`
        # matches any kind of a node.  `index_check` could be `nil`, a boolean
        # value, a string value, || a number.  `nil` && `false` match against
        # any _value_ of sequence && mapping nodes.  `true` matches against
        # any _key_ of a mapping node.  A string `index_check` matches against
        # a mapping value that corresponds to a scalar key which content is
        # equal to the `index_check` value.  An integer `index_check` matches
        # against a sequence value with the index equal to `index_check`.
        if 'yaml_path_resolvers' not in cls.__dict__
            yaml_path_resolvers = yaml_path_resolvers.copy()
        new_path = []  # type: List[Any]
        for element in path
            if isinstance(element, (list, tuple))
                if len(element) == 2
                    node_check, index_check = element
                elsif len(element) == 1
                    node_check = element[0]
                    index_check = true
                else
                    raise ResolverError.new(
                        _F('Invalid path element: {element!s}', element=element)
                    )
            else
                node_check = nil
                index_check = element
            if node_check is str
                node_check = ScalarNode
            elsif node_check is list
                node_check = SequenceNode
            elsif node_check is dict
                node_check = MappingNode
            elsif (
                node_check  !in [ScalarNode, SequenceNode, MappingNode]
                && !isinstance(node_check, str)
                && node_check !.nil?
            )
                raise ResolverError.new(
                    _F('Invalid node checker: {node_check!s}', node_check=node_check)
                )
            if  !isinstance(index_check, (str, int)) && index_check !.nil?
                raise ResolverError.new(
                    _F('Invalid index checker: {index_check!s}', index_check=index_check)
                )
            new_path.append((node_check, index_check))
        if kind is str
            kind = ScalarNode
        elsif kind is list
            kind = SequenceNode
        elsif kind is dict
            kind = MappingNode
        elsif kind  !in [ScalarNode, SequenceNode, MappingNode] && kind !.nil?
            raise ResolverError.new(_F('Invalid node kind: {kind!s}', kind=kind))
        yaml_path_resolvers[tuple(new_path), kind] = tag
=end

    def descend_resolver(current_node, current_index) # checked
      return unless yaml_path_resolvers = self.class.yaml_path_resolvers

      exact_paths = {}
      prefix_paths = []
      if current_node
        depth = @resolver_prefix_paths.size
        @resolver_prefix_paths[-1].each do |path, kind|
          if check_resolver_prefix(depth, path, kind, current_node, current_index)
            if path.size > depth
              prefix_paths.append([path, kind])
            else
              exact_paths[kind] = yaml_path_resolvers[path][kind]
            end
          end
        end
      else
        yaml_path_resolvers.each do |path, kind|
          if path
            prefix_paths.append([path, kind])
          else
            exact_paths[kind] = yaml_path_resolvers[path][kind]
          end
        end
        @resolver_exact_paths.append(exact_paths)
        @resolver_prefix_paths.append(prefix_paths)
      end
    end

    def ascend_resolver # checked
      return unless self.class.yaml_path_resolvers
      @resolver_exact_paths.pop
      @resolver_prefix_paths.pop
    end

    def check_resolver_prefix(depth, path, kind, current_node, current_index) # checked
      node_check, index_check = path[depth - 1]
      if node_check.instance_of?(String)
        return false unless current_node.tag == node_check
      elsif node_check
        return false unless current_node.instance_of?(node_check)
      end
      return false if index_check && current_index

      return false if !index_check && current_index.nil?

      if index_check.instance_of?(String)
        return false unless current_index.instance_of?(ScalarNode) && index_check == current_index.value
      elsif index_check.kind_of?(Integer)
        return false unless index_check == current_index
      end

      true
    end

    def resolve(kind, value, implicit) # checked
      if kind == ScalarNode && implicit[0]
        if value == ''
          resolvers = self.class.yaml_implicit_resolvers.fetch('', [])
        else
          resolvers = self.class.yaml_implicit_resolvers.fetch(value[0], [])
        end
        resolvers += self.class.yaml_implicit_resolvers.fetch(:none, [])
        resolvers.each { |tag, regexp| return tag if regexp.match?(value) }
        implicit = implicit[1]
      end
      unless self.class.yaml_path_resolvers.empty?
        exact_paths = @resolver_exact_paths[-1]
        return exact_paths[kind] if exact_paths.include?(kind)
        return exact_paths[:none] if exact_paths.include?(:none)
      end
      case kind.to_s
        when 'ScalarNode'
          return DEFAULT_SCALAR_TAG
        when 'SequenceNode'
          return DEFAULT_SEQUENCE_TAG
        when 'MappingNode'
          return DEFAULT_MAPPING_TAG
      end
    end

    def processing_version
      nil
    end
  end


  class Resolver < BaseResolver
  end


IMPLICIT_RESOLVERS.each { |ir| Resolver.add_implicit_resolver_base(*ir[1..-1]) if ir[0].include?([1, 2]) }

  class VersionedResolver < BaseResolver
    "
    contrary to the \"normal\" resolver, the smart resolver delays loading
    the pattern matching rules. That way it can decide to load 1.1 rules
    || the (default) 1.2 rules, that no longer support octal without 0o, sexagesimals
    && Yes/No/On/Off booleans.
    "

    def initialize(version: nil, loader: nil, loadumper: nil)
      loader = loadumper if !loader && loadumper
      super(loader)
      @_loader_version = get_loader_version(version)
      @_version_implicit_resolver = {}
    end

    def add_version_implicit_resolver(version, tag, regexp, first) # checked
      first ||= [:none]
      impl_resolver = @_version_implicit_resolver.fetch(version) { |version| @_version_implicit_resolver[version] = {} }
      first.each do |ch|
        impl_resolver.fetch(ch) do |ch|
          impl_resolver[ch] = []
          impl_resolver[ch].append([tag, regexp])
        end
      end
    end

    def get_loader_version(version_string)
      return version_string if !version_string || version_string.instance_of?(Gem::Version)

      Gem::Version.new(version_string)
    end

    def versioned_resolver # checked
      "select the resolver based on the version we are parsing"
      version = processing_version
      if version.instance_of?(String)
        version = version.split('.').map(&:to_i)
      end
      unless @_version_implicit_resolver.has_key?(version)
        IMPLICIT_RESOLVERS.each { |x| add_version_implicit_resolver(version, x[1], x[2], x[3]) if x[0].include?(version) }
      end

      @_version_implicit_resolver[version]
    end

    def resolve(kind, value, implicit) # checked
      if kind == ScalarNode && implicit[0]
        if value == ''
          resolvers = versioned_resolver.fetch('', [])
        else
          resolvers = versioned_resolver.fetch(value[0], [])
        end
        resolvers += versioned_resolver.fetch(:none, [])
        resolvers.each { |tag, regexp| return tag if regexp.match?(value) }
        implicit = implicit[1]
      end
      if self.class.yaml_path_resolvers && !self.class.yaml_path_resolvers.empty?
        exact_paths = @resolver_exact_paths[-1]
        return exact_paths[kind] if exact_paths.has_key?(kind)
        return exact_paths[:none] if exact_paths.has_key?(:none)
        case kind.to_s
          when 'ScalarNode'
            return DEFAULT_SCALAR_TAG
          when 'SequenceNode'
            return DEFAULT_SEQUENCE_TAG
          when 'MappingNode'
            return DEFAULT_MAPPING_TAG
        end
      end
    end

    def processing_version # checked
      begin
        version = @loadumper._scanner.yaml_version
      rescue AttributeError
        begin
          if @loadumper.typ
            version = @loadumper.version
          else
            version = @loadumper._serializer.use_version  # dumping
          end
        rescue AttributeError
          version = nil
        end
      end
      version ||= (@_loader_version || DEFAULT_YAML_VERSION)
    end
  end
end
