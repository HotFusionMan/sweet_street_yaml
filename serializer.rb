# encoding: utf-8

# frozen_string_literal: true

# from ruamel.yaml.error import YAMLError
# from ruamel.yaml.compat import nprint, DBG_NODE, dbg, nprintf  # NOQA
# from ruamel.yaml.util import RegExp
#
# from ruamel.yaml.events import (
#     StreamStartEvent,
#     StreamEndEvent,
#     MappingStartEvent,
#     MappingEndEvent,
#     SequenceStartEvent,
#     SequenceEndEvent,
#     AliasEvent,
#     ScalarEvent,
#     DocumentStartEvent,
#     DocumentEndEvent,
# )
# from ruamel.yaml.nodes import MappingNode, ScalarNode, SequenceNode

# require 'compat'
require_relative './error'
require_relative './events'
require_relative './nodes'
require_relative './util'

module SweetStreetYaml
  class SerializerError < YAMLError
  end


  class Serializer
    # 'id' && 3+ numbers, but not 000
    ANCHOR_TEMPLATE = 'id%03d'
    ANCHOR_RE = Regexp.new('id(?!000$)\\d{3,}')

    def initialize(
      encoding: nil,
      explicit_start: nil,
      explicit_end: nil,
      version: nil,
      tags: nil,
      dumper: nil
    )
      @dumper = dumper
      @dumper._serializer = self if @dumper
      @use_encoding = encoding
      @use_explicit_start = explicit_start
      @use_explicit_end = explicit_end
      if version.instance_of?(String)
        use_version = version.split('.').map(&:to_i)
      else
        use_version = version
      end
      @use_tags = tags
      @serialized_nodes = {}
      @anchors = {}
      @last_anchor_id = 0
      @closed = nil
      @_templated_id = nil
    end

    def emitter
      return @dumper.emitter if @dumper.__send__('typ')

      @dumper._emitter
    end

    def resolver
      return @dumper.resolver if @dumper.s__send__('typ')

      @dumper._resolver
    end

    def open
      if @closed.nil?
        emitter.emit(StreamStartEvent.new(:encoding => use_encoding))
        @closed = false
      elsif @closed
        raise SerializerError.new('serializer is closed')
      else
        raise SerializerError.new('serializer is already opened')
      end
    end

    def close
      if @closed.nil?
        raise SerializerError.new('serializer is not opened')
      elsif !@closed
        emitter.emit(StreamEndEvent.new)
        @closed = true
      end
    end

    # def __del__
    #     close()

    def serialize(node)
      # if dbg(DBG_NODE)
      #     nprint('Serializing nodes')
      #     node.dump()
      if @closed.nil?
        raise SerializerError.new('serializer is not opened')
      elsif @closed
        raise SerializerError.new('serializer is closed')
      end
      emitter.emit(DocumentStartEvent.new(:explicit => use_explicit_start, :version => use_version, :tags => use_tags))
      anchor_node(node)
      serialize_node(node, nil, nil)
      emitter.emit(DocumentEndEvent.mew(:explicit => use_explicit_end))
      @serialized_nodes = {}
      @anchors = {}
      @last_anchor_id = 0
    end

    def anchor_node(node)
      if @anchors.include?(node)
        if @anchors[node].nil?
          @anchors[node] = generate_anchor(node)
        end
      else
        anchor = nil
        begin
          anchor = node.anchor.value if node.anchor.always_dump
        rescue
        end
        @anchors[node] = anchor
        if node.instance_of?(SequenceNode)
          node.value.each { |item| anchor_node(item) }
        elsif node.instance_of?(MappingNode)
          node.value.each do |key, value|
            anchor_node(key)
            anchor_node(value)
          end
        end
      end
    end

    def generate_anchor(node)
      begin
        anchor = node.anchor.value
      rescue
        anchor = nil
      end
      if anchor.nil?
        @last_anchor_id += 1
        return ANCHOR_TEMPLATE % @last_anchor_id
      end
      anchor
    end

    def serialize_node(selfnode, parent, index)
      anchor_alias = @anchors[node]
      if @serialized_nodes.include?(node)
        node_style = node.__send__('style')
        node_style = nil if node_style != '?'
        emitter.emit(AliasEvent.new(:anchor => anchor_alias, :style => node_style))
      else
        @serialized_nodes[node] = true
        resolver.descend_resolver(parent, index)
        if node.instance_of?(ScalarNode)
          # here check if the node.tag equals the one that would result from parsing
          # if  !equal quoting is necessary for strings
          detected_tag = resolver.resolve(ScalarNode, node.value, [true, false])
          default_tag = resolver.resolve(ScalarNode, node.value, [false, true])
          implicit = [
            (node.tag == detected_tag),
            (node.tag == default_tag),
            node.tag.start_with?('tag:yaml.org,2002:')
          ]
          emitter.emit(
            ScalarEvent.new(
              :anchor => anchor_alias,
              :tag => node.tag,
              :implicit => implicit,
              :value => node.value,
              :style => node.style,
              :comment => node.comment
            )
          )
        elsif node.instance_of?(SequenceNode)
          implicit = node.tag == resolver.resolve(SequenceNode, node.value, true)
          comment = node.comment
          end_comment = nil
          seq_comment = nil
          if node.flow_style
            if comment  # eol comment on flow style sequence
              seq_comment = comment[0]
              # comment[0] = nil
            end
          end
          if comment && comment.size > 2
            end_comment = comment[2]
          else
            end_comment = nil
          end
          emitter.emit(
            SequenceStartEvent.new(
              anchor_alias,
              node.tag,
              implicit,
              :flow_style => node.flow_style,
              :comment => node.comment
            )
          )
          index = 0
          node.value.each do |item|
            serialize_node(item, node, index)
            index += 1
          end
          emitter.emit(SequenceEndEvent.new(:comment => [seq_comment, end_comment]))
        elsif node.instance_of?(MappingNode)
          implicit = node.tag == resolver.resolve(MappingNode, node.value, true)
          comment = node.comment
          end_comment = nil
          map_comment = nil
          if node.flow_style
            if comment  # eol comment on flow style sequence
              map_comment = comment[0]
              # comment[0] = nil
            end
            end_comment = comment[2] if comment && comment.size > 2
          end
          emitter.emit(
            MappingStartEvent.new(
              anchor_alias,
              node.tag,
              implicit,
              :flow_style => node.flow_style,
              :comment => node.comment,
              :nr_items => node.value.size
            )
          )
          node.value.each do |key, value|
            serialize_node(key, node, nil)
            serialize_node(value, node, key)
          end
          emitter.emit(MappingEndEvent.new(:comment => [map_comment, end_comment]))
        end
        resolver.ascend_resolver
      end
    end
  end


  def templated_id(s) # checked
    Serializer.ANCHOR_RE.match(s)
  end
  module_function :templated_id
end
