# encoding: utf-8

# frozen_string_literal: true

# from ruamel.yaml.compat import _F, nprintf  # NOQA
# require 'compat'

module SweetStreetYaml
SHOW_LINES = true

  class Token
    attr_accessor :start_mark, :end_mark, :_comment

    def initialize(start_mark, end_mark)
      @start_mark = start_mark
      @end_mark = end_mark
    end

    def to_s
      attributes = instance_variables.reject { |attr| attr.to_s.end_with?('_mark') }
      attributes.sort!
      arguments = attributes.map! { |key| "#{key}='#{self.__send__(key)}'" }
      if SHOW_LINES
        begin
          arguments.append('line: ' + @start_mark.line.to_s)
        rescue
        end
      end
      begin
        arguments.append('comment: ' + @_comment.to_s)
      rescue
      end

      "#{self.class.name}(#{arguments.join(', ')})"
    end

    def column
      @start_mark.column
    end

    def column=(pos)
      @start_mark.column = pos
    end

    # new style ( >= 0.17 ) is a THREE element list with the first being a list of
    # preceding FLC/BLNK, the second EOL && the third following FLC/BLNK
    # note that new style has differing order, && does not consist of CommentToken.new(s)
    # but of CommentInfo instances
    # any non-assigned values in new style are nil, but first && last can be empty list
    # new style routines add one comment at a time

    # new style
    def add_comment_pre(comment)
      if _comment
        raise unless _comment.size == 3
        _comment[0] ||= []
      else
        _comment = [[], nil, nil]
      end
      _comment[0].append(comment)
    end

    def add_comment_eol(comment, comment_type)
      if _comment

        raise if _comment[1]
      else
        _comment = [nil, nil, nil]
      end
      _comment[1] ||= []
      _comment[1] += ([nil] * (comment_type + 1 - comment[1].size))
      _comment[1][comment_type] = comment
    end

    def add_comment_post(comment)
      if _comment
        raise unless _comment.size == 3
        _comment[2] ||= []
      else
        _comment = [nil, nil, []]
      end
      _comment[2].append(comment)
    end

    def comment
      @_comment
    end

    def move_old_comment(target, empty = false)
      "move a comment from this token to target (normally next token)
        used to combine e.g. comments before a BlockEntryToken to the
        ScalarToken that follows it
        empty is a special for empty values -> comment after key
        "
      c = comment
      return unless c

      # don't push beyond last element
      return if target.instance_of?(StreamEndToken) || target.instance_of?(DocumentStartToken)
      @_comment = nil
      tc = target.comment
      unless tc # target comment, just insert
        # special for empty value in key: value issue 25
        c = [c[0], c[1], nil, nil, c[0]] if empty
        target._comment = c
        return self
      end
      raise NotImplementedError.new("overlap in comment '#{c}' '#{tc}'") if c[0] && tc[0] || c[1] && tc[1]
      tc[0] = c[0] if c[0]
      tc[1] = c[1] if c[1]
      return self
    end

    def split_old_comment
      " split the post part of a comment, and return it
        as comment to be added. Delete second part if [nil, nil]
         abc:  # this goes to sequence
           # this goes to first element
           - first element
        "
      return nil if @_comment.nil? || @_comment[0].nil? # nothing to do
      ret_val = [@_comment[0], nil]
      @_comment = nil if @_comment[1].nil?
      ret_val
    end

    def move_new_comment(target, empty = false)
      "move a comment from this token to target (normally next token)
        used to combine e.g. comments before a BlockEntryToken to the
        ScalarToken that follows it
        empty is a special for empty values -> comment after key
        "
      c = comment
      return unless c
      # don't push beyond last element
      return if target.instance_of?(StreamEndToken) || target.instance_of?(DocumentStartToken)
      @_comment = nil
      tc = target.comment
      unless tc  # target comment, just insert
        # special for empty value in key: value issue 25
        c = [c[0], c[1], c[2]] if empty
        target._comment = c
        return self
      end
      0.upto(2) { |idx| raise NotImplementedError.new("overlap in comment '#{c}' '#{tc}'") if c[idx] && tc[idx] }
      # move the comment parts
      0.upto(2) { |idx| tc[idx] = c[idx] if c[idx] }
      self
    end
  end


  class DirectiveToken < Token
    attr_accessor :name, :value
    @id = '<directive>'

    def initialize(name, value, start_mark, end_mark)
      super(start_mark, end_mark)
      @name = name
      @value = value
    end
  end


  class DocumentStartToken < Token
    @id = '<document start>'
  end


  class DocumentEndToken < Token
    # attr_accessor :()
    @id = '<document end>'
  end


  class StreamStartToken < Token
    attr_accessor :encoding
    @id = '<stream start>'

    def initialize(start_mark = nil, end_mark = nil, encoding = nil)
        super(start_mark, end_mark)
        @encoding = encoding
    end
  end


  class StreamEndToken < Token
    @id = '<stream end>'
  end


  class BlockSequenceStartToken < Token
    attr_accessor :encoding
    @id = '<block sequence start>'
  end


  class BlockMappingStartToken < Token
    @id = '<block mapping start>'
  end


  class BlockEndToken < Token
    @id = '<block end>'
  end


  class FlowSequenceStartToken < Token
    @id = '['
  end


  class FlowMappingStartToken < Token
    @id = '{'
  end


  class FlowSequenceEndToken < Token
    @id = ']'
  end


  class FlowMappingEndToken < Token
    @id = '}'
  end


  class KeyToken < Token
    id = '?'
  end


  class ValueToken < Token
    @id = ':'
  end


  class BlockEntryToken < Token
    @id = '-'
  end


  class FlowEntryToken < Token
    @id = ','
  end


  class AliasToken < Token
    attr_accessor :value
    @id = '<alias>'

    def initialize(value, start_mark, end_mark)
        super(start_mark, end_mark)
        @value = value
    end
  end


  class AnchorToken < Token
    attr_accessor :value
    @id = '<anchor>'

    def initialize(value, start_mark, end_mark)
        super(start_mark, end_mark)
        @value = value
    end
  end


  class TagToken < Token
    attr_accessor :value
    @id = '<tag>'

    def initialize(value, start_mark, end_mark)
        super(start_mark, end_mark)
        @value = value
    end
  end


  class ScalarToken < Token
    attr_accessor :value, :plain, :style
    @id = '<scalar>'

    def initialize(value, plain, start_mark, end_mark, style=nil)
        super(start_mark, end_mark)
        @value = value
        @plain = plain
        @style = style
    end
  end


  class CommentToken < Token
    attr_accessor :_value, :pre_done
    @id = '<comment>'

    def initialize(value, start_mark = nil, end_mark = nil, column = nil)
      if start_mark.nil?
        raise unless column
        @_column = column
      end
      super(start_mark, nil)
      @_value = value
    end

    def value
      return @_value if @_value.instance_of?(String)

      @_value.join('')
    end

    def value=(val)
      @_value = val
    end

    def reset
      @pre_done = nil if @pre_done
    end

    def to_s
      v = "'#{value}'"
      if SHOW_LINES
        begin
          v += ', line: ' + start_mark.line.to_s
        rescue
        end
        begin
          v += ', col: ' + start_mark.column.to_s
        rescue
        end
      end
      "CommentToken.new(#{v})"
    end

    def ==(other)
      return false if start_mark != other.start_mark

      return false if end_mark != other.end_mark

      return false if value != other.value

      true
    end

    # def __ne__(self, other)
    #     return  !__eq__(other)
  end
end
