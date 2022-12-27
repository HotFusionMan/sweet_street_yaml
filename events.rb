# encoding: utf-8

# frozen_string_literal: true

# from ruamel.yaml.compat import _F
# require 'compat'

# Abstract classes.


module SweetStreetYaml

  class Event
    SHOW_LINES = false

    attr_accessor :start_mark, :end_mark, :comment

    def initialize(start_mark: nil, end_mark: nil, comment: comment_check)
      @start_mark = start_mark
      @end_mark = end_mark
      @comment =
        if comment == comment_check
          nil
        else
          comment
        end
    end

    def comment_check
      nil
    end

    def to_s
      if true
        arguments = []
        if value
          # if you use repr(getattr(self, 'value')) then flake8 complains about
          # abuse of getattr with a constant. When you change to value
          # then mypy throws an error
          arguments.append(value.to_s)
        end
        ['anchor', 'tag', 'implicit', 'flow_style', 'style'].each do |key|
          v = __send__(key)
          arguments.append("#{key}=#{v}") if v
        end
        arguments.append("comment=#{@comment}") unless [nil, comment_check].include?(comment)
        if SHOW_LINES
          arguments.append(
            "(#{@start_mark.line}:#{@start_mark.column}/#{@end_mark.line}:#{@end_mark.column})"
          )
        end
        arguments = arguments.join(', ')
      # else
      #     attributes = [
      #         key
      #         for key in ['anchor', 'tag', 'implicit', 'value', 'flow_style', 'style']
      #         if hasattr(self, key)
      #     ]
      #     arguments = ', '.join(
      #         [_F('{k!s}={attr!r}', k=key, attr=getattr(self, key)) for key in attributes]
      #     )
      #     if comment  !in [nil, comment_check]
      #         arguments += ', comment={!r}'.format(comment)
      end
      "#{self.class.name}(#{arguments})"
    end
  end


  class NodeEvent < Event
    attr_accessor :anchor

    def initialize(anchor:, start_mark: nil, end_mark: nil, comment: nil)
      super(:start_mark => nil, :end_mark => nil, :comment => nil)
      @anchor = anchor
    end
  end


  class CollectionStartEvent < NodeEvent
    attr_accessor :tag, :implicit, :flow_style, :nr_items

    def initialize(
      anchor:,
      tag:,
      implicit:,
      start_mark: nil,
      end_mark: nil,
      flow_style: nil,
      comment: nil,
      nr_items: nil
    )
      super(:anchor => anchor, :start_mark => start_mark, :end_mark => end_mark, :comment => comment)
      @tag = tag
      @implicit = implicit
      @flow_style = flow_style
      @nr_items = nr_items
    end
  end


  class CollectionEndEvent < Event
  end
    

# Implementations.


  class StreamStartEvent < Event
    attr_accessor :encoding, :anchor

    def initialize(start_mark: nil, end_mark: nil, encoding: nil, comment: nil)
      super(:start_mark => start_mark, :end_mark => end_mark, :comment => comment)
      @encoding = encoding
    end
  end


  class StreamEndEvent < Event
  end


  class DocumentStartEvent < Event
    attr_accessor :explicit, :version, :tags

    def initialize(
      start_mark: nil,
      end_mark: nil,
      explicit: nil,
      version: nil,
      tags: nil,
      comment: nil
    )
      super(:start_mark => start_mark, :end_mark => end_mark, :comment => comment)
      @explicit = explicit
      @version = version
      @tags = tags
    end
  end


  class DocumentEndEvent < Event
    attr_accessor :explicit

    def initialize(start_mark: nil, end_mark: nil, explicit: nil, comment: nil)
      super(:start_mark => start_mark, :end_mark => end_mark, :comment => comment)
      @explicit = explicit
    end
  end


  class AliasEvent < NodeEvent
    attr_accessor :style

    def initialize(anchor:, start_mark: nil, end_mark: nil, style: nil, comment: nil)
      super(:anchor => anchor, :start_mark => start_mark, :end_mark => end_mark, :comment => comment)
      @style = style
    end
  end


  class ScalarEvent < NodeEvent
    attr_accessor :tag, :implicit, :value, :style

    def initialize(
      anchor:,
      tag:,
      implicit:,
      value:,
      start_mark: nil,
      end_mark: nil,
      style: nil,
      comment: nil
    )
      super(:anchor => anchor, :start_mark => start_mark, :end_mark => end_mark, :comment => comment)
      @tag = tag
      @implicit = implicit
      @value = value
      @style = style
    end
  end


  class SequenceStartEvent < CollectionStartEvent
  end


  class SequenceEndEvent < CollectionEndEvent
  end


  class MappingStartEvent < CollectionStartEvent
  end


  class MappingEndEvent < CollectionEndEvent
  end
end
