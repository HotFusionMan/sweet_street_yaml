# encoding: utf-8

# frozen_string_literal: true

"
stuff to deal with comments and formatting on dict/list/ordereddict/set
these are not really related, formatting could be factored out as
a separate base
"

# import sys
# import copy


# from ruamel.yaml.compat import ordereddict
# from ruamel.yaml.compat import MutableSliceableSequence, _F, nprintf  # NOQA
# from ruamel.yaml.scalarstring import ScalarString
# from ruamel.yaml.anchor import Anchor

require_relative './error'
require_relative './tokens'

require 'set'

# from collections.abc import MutableSet, Sized, Set, Mapping

# splitting of comments by the scanner
# an EOLC (End-Of-Line Comment) is preceded by some token
# an FLC (Full Line Comment) is a comment not preceded by a token, i.e. # is
#   the first non-blank on line
# a BL is a blank line i.e. empty or spaces/tabs only
# bits 0 and 1 are combined, you can choose only one
C_POST = 0b00
C_PRE = 0b01
C_SPLIT_ON_FIRST_BLANK = 0b10  # as C_POST, but if blank line then C_PRE all lines before
# first blank goes to POST even if no following real FLC
# (first blank -> first of post)
# 0b11 -> reserved for future use
C_BLANK_LINE_PRESERVE_SPACE = 0b100
# C_EOL_PRESERVE_SPACE2 = 0b1000

module SweetStreetYaml
  class IDX
    # temporary auto increment, so rearranging is easier
    def initialize
      @_idx = 0
    end

    def __call__
      x = @_idx
      @_idx += 1
      x
    end

    def to_s
      @_idx.to_s
    end
  end


  # more or less in order of subjective expected likelyhood
  # the _POST and _PRE ones are lists themselves
  C_VALUE_EOL = C_ELEM_EOL = IDX.new
  C_KEY_EOL = IDX.new
  C_KEY_PRE = C_ELEM_PRE = IDX.new  # not this is not value
  C_VALUE_POST = C_ELEM_POST = IDX.new  # not this is not value
  C_VALUE_PRE = IDX.new
  C_KEY_POST = IDX.new
  C_TAG_EOL = IDX.new
  C_TAG_POST = IDX.new
  C_TAG_PRE = IDX.new
  C_ANCHOR_EOL = IDX.new
  C_ANCHOR_POST = IDX.new
  C_ANCHOR_PRE = IDX.new


  COMMENT_ATTRIB = '_yaml_comment'
  FORMAT_ATTRIB = '_yaml_format'
  LINE_COL_ATTRIB = '_yaml_line_col'
  MERGE_ATTRIB = '_yaml_merge'
  TAG_ATTRIB = '_yaml_tag'


  class Comment
    attr_accessor :comment, :_items, :_post, :_pre

    def self.attrib
      SweetStreetYaml::COMMENT_ATTRIB
    end

    def initialize(old = true)
      @_pre = old ? nil : []
      @comment = nil
      # map key (mapping/omap/dict) or index (sequence/list) to a  list of
      # dict: post_key, pre_key, post_value, pre_value
      # list: pre item, post item
      @_items = {}
      # _start = [] # should not put these on first item
      @_post = [] # end of document comments
    end

    def to_s
      if @_post.to_boolean
        the_end = ',\n  end=' + str(_post)
      else
        the_end = ''
      end
      "Comment(comment=#{@comment},\n  items=#{@_items}#{the_end})"
    end

    # def _old__repr__
    #     # type: () -> str
    #     if bool(_post)
    #         end = ',\n  end=' + str(_post)
    #     else
    #         end = ""
    #     try
    #         ln = max([len(str(k)) for k in _items]) + 1
    #     rescue ValueError
    #         ln = ''  # type: ignore
    #     it = '    '.join(
    #         ['{:{}} {}\n'.format(str(k) + ':', ln, v) for k, v in _items.items()]
    #     )
    #     if it
    #         it = '\n    ' + it + '  '
    #     return 'Comment(\n  start={},\n  items={{{}}}{})'.format(comment, it, end)
    #
    # def __repr__
    #     # type: () -> str
    #     if _pre .nil?
    #         return _old__repr__()
    #     if bool(_post)
    #         end = ',\n  end=' + repr(_post)
    #     else
    #         end = ""
    #     try
    #         ln = max([len(str(k)) for k in _items]) + 1
    #     rescue ValueError
    #         ln = ''  # type: ignore
    #     it = '    '.join(
    #         ['{:{}} {}\n'.format(str(k) + ':', ln, v) for k, v in _items.items()]
    #     )
    #     if it
    #         it = '\n    ' + it + '  '
    #     return 'Comment(\n  pre={},\n  items={{{}}}{})'.format(pre, it, end)

    def items
      @_items
    end

    def _end
      @_post
    end

    def _end=(value)
      @_post = value
    end

    def pre
      @_pre
    end

    def pre=(value)
      @_pre = value
    end

    def get(item, pos)
      x = @_items.get(item)
      return nil if x.nil? || x.size < pos
      x[pos]  # can be nil
    end

    def set(item, pos, value) # checked
      x = @_items.fetch(item)
      if x.nil?
        @_items[item] = x = Array.new(pos + 1, nil)
      else
        while x.size <= pos
          x.append(nil)
        end
      end
      raise unless x[pos].nil?
      x[pos] = value
    end

    def __contains__(x)
      # test if a substring is in any of the attached comments
      if @comment
        return true if @comment[0] && @comment[0].value.include?(x)
        if @comment[1]
          @comment[1].each { |c| return true if c.value.include?(x)}
        end
      end
      items.values.each do |value|
        next unless value
        value.each { return true if c && c.value.include?(x) }
        if _end
          _end.each { |c| return true if c.value.include?(x) }
        end
      end
      false
    end
  end


  # to distinguish key from nil
  def NoComment
  end


  class Format
    attr_accessor :_flow_style
    attrib = FORMAT_ATTRIB

    def initialize
      @_flow_style = nil
    end

    def set_flow_style
      @_flow_style = true
    end

    def set_block_style
      @_flow_style = false
    end

    def flow_style(default = nil)
      "if default (the flow_style) .nil?, the flow style tacked on to
        the object explicitly will be taken. If that .nil? as well the
        default flow style rules the format down the line, or the type
        of the constituent values (simple -> flow, map/list -> block)"
      @_flow_style ? @_flow_style : default
    end
  end


  class LineCol
    "line and column information wrt document, values start at zero (0)"

    def self.attrib
      SweetStreetYaml::LINE_COL_ATTRIB
    end

    def initialize
      @line = nil
      @col = nil
      @data = nil
    end

    def add_kv_line_col(key, data) # checked
      @data ||= {}
      @data[key] = data
    end
    alias :add_idx_line_col :add_kv_line_col

    def key(k)
      _kv(k, 0, 1)
    end

    def value(k)
      _kv(k, 2, 3)
    end

    def _kv(k, x0, x1)
      return nil unless @data

      data = @data[k]
      [data[x0], data[x1]]
    end

    def item(idx)
      return nil unless @data

      [@data[idx][0], @data[idx][1]]
    end

    def to_s
      _F('LineCol({line}, {col})', line=line, col=col)
    end
  end


  class Tag
    "store tag information for roundtripping"

    attr_accessor :value

    def self.attrib
      SweetStreetYaml::TAG_ATTRIB
    end

    def initialize
      @value = nil
    end

    def to_s
      '{0.__class__.__name__}({0.value!r})'.format
    end
  end


  class CommentedBase
    def ca # checked
      instance_variable_set("@#{Comment.attrib}".to_sym, Comment.new) unless self.__send__(Comment.attrib)

      self.__send__(Comment.attrib)
    end

    def yaml_end_comment_extend(comment, clear = false) # checked
      return unless comment

      ca._end = [] if clear || ca._end.nil?
      ca.end += comment
    end

    def yaml_key_comment_extend(key, comment, clear = false) # checked
      ca.items.default = [nil, nil, nil, nil]
      r = ca.items[key]
      if clear || r[1].nil?
        if comment[1]
          raise unless comment[1].instance_of?(Array)
        end
        r[1] = comment[1]
      else
        r[1] += comment[0]
      end
      r[0] = comment[0]
    end

    def yaml_value_comment_extend(key, comment, clear = false)
      r = ca.items.default = [nil, nil, nil, nil]
      if clear || r[3].nil?
        if comment[1]
          raise unless comment[1].instance_of?(Array)
        end
        r[3] = comment[1]
      else
        r[3] += comment[0]
      end
      r[2] = comment[0]
    end

    def yaml_set_start_comment(comment, indent = 0)
      "overwrites any preceding comment lines on an object
        expects comment to be without `#` and possible have multiple lines
        "
      # from .error import CommentMark
      # from .tokens import CommentToken

      pre_comments = _yaml_clear_pre_comment
      comment.chomp!
      start_mark = CommentMark.new(indent)
      comment.split("\n").each do |com|
        c = com.strip
        com.prepend('# ') if c.size > 0 && c[0] != '#'
        pre_comments.append(CommentToken.new(com + "\n", start_mark))
      end
    end

    def comment_token(s, mark)
      # handle empty lines as having no comment
      CommentToken.new((s ? '# ' : '') + s + "\n", mark)
    end

    def yaml_set_comment_before_after_key(key, before = nil, indent = 0, after = nil, after_indent = nil)
      "
        expects comment (before/after) to be without `#` and possible have multiple lines
        "
      # from ruamel.yaml.error import CommentMark
      # from ruamel.yaml.tokens import CommentToken

      after_indent ||= indent + 2
      before&.chomp!
      after&.chomp! # strip final newline if there
      start_mark = CommentMark,new(indent)
      c = ca.items.default = [nil, [], nil, nil]
      if before.to_boolean
        c[1] ||= []
        if before == "\n"
          c[1].append(comment_token('', start_mark))
        else
          before.split("\n").each do |com|
            c[1].append(comment_token(com, start_mark))
          end
        end
        if after.to_boolean
          start_mark = CommentMark.new(after_indent)
          c[3] ||= []
          after.split("\n").each do |com|
            c[3].append(comment_token(com, start_mark))
          end
        end
      end
    end

    def fa
      "format attribute

        set_flow_style()/set_block_style()"
      instance_variable_set("@#{Format.attrib}".to_sym, Format.new) unless self.__send__(Format.attrib)
      self.__send__(Format.attrib)
    end

    def yaml_add_eol_comment(comment, key = NoComment, column = nil)
      "
        there is a problem as eol comments should start with ' #'
        (but at the beginning of the line the space doesn't have to be before
        the #. The column index is for the # mark
        "
      # from .tokens import CommentToken
      # from .error import CommentMark

      unless column
        begin
          column = _yaml_get_column(key)
        rescue AttributeError
          column = 0
        end
      end
      if comment[0] != '#'
        comment.prepend('# ')
      end
      unless column
        if comment[0] == '#'
          comment.prepend(' ')
          column = 0
        end
      end
      start_mark = CommentMark.new(column)
      ct = [CommentToken.new(comment, start_mark), nil]
      _yaml_add_eol_comment(ct, :key => key)
    end

    def lc # checked
      instance_variable_set("@#{LineCol.attrib}".to_sym, LineCol.new) unless self.__send__(LineCol.attrib)
      self.__send__(LineCol.attrib)
    end

    def _yaml_set_line_col(line, col)
      lc.line = line
      lc.col = col
    end

    def _yaml_set_kv_line_col(key, data) # checked
      lc.add_kv_line_col(key, data)
    end

    def _yaml_set_idx_line_col(key, data)
      lc.add_idx_line_col(key, data)
    end

    def anchor
      instance_variable_set("@#{Anchor.attrib}".to_sym, Anchor.new) unless self.__send__(Anchor.attrib)
      self.__send__(Anchor.attrib)
    end

    def yaml_anchor
      return nil unless self.__send__(Anchor.attrib)

      anchor
    end

    def yaml_set_anchor(value, always_dump = false)
        anchor.value = value
        anchor.always_dump = always_dump
    end
    
    def tag
      instance_variable_set("@#{Tag.attrib}".to_sym, Tag.new) unless self.__send__(Tag.attrib)
      self.__send__(Tag.attrib)
    end

    def yaml_set_tag(value)
      tag.value = value
    end

    def copy_attributes(t, memo = nil)
      [Comment.attrib, Format.attrib, LineCol.attrib, Anchor.attrib, Tag.attrib, merge_attrib].each do |a|
        if self.__send__(a)
          if memo
            t.instance_variable_set("@#{a}".to_sym, a.deep_dup)
          else
            t.instance_variable_set("@#{a}".to_sym, self.__send__(a))
          end
        end
      end
    end

    def _yaml_add_eol_comment(comment, key)
      raise NotImplementedError
    end

    def _yaml_get_pre_comment
      raise NotImplementedError
    end

    def _yaml_get_column(key)
      raise NotImplementedError
    end
  end


  class CommentedSeq < CommentedBase
    attr_accessor Comment.attrib.to_sym, :_lst

    def initialize(*args)
      @_lst = Array.new(*args)
    end

    def [](idx)
      @_lst[idx]
    end

    def []=(idx, value)
      # begin to preserve the scalarstring type if setting an existing key to a new value
      if idx < size
        value = self[idx].class.new(value) if value.instance_of?(String) && self[idx].instance_of?(ScalarString)
      end
      @_lst[idx] = value
    end

    def delete(idx = nil)
      @_lst.delete(idx)
      ca.items.delete(idx)
      ca.items.sort.each do |list_index|
        next if list_index < idx
        ca.items[list_index - 1] = ca.items.delete_at(list_index)
      end
    end

    def size
      @_lst.size
    end
    alias :length :size

    def insert(idx, val)
      "the comments after the insertion have to move forward"
      @_lst.insert(idx, val)
      ca.items.sort.reverse_each do |list_index|
        break if list_index < idx
        ca.items[list_index + 1] = ca.items.delete_at(list_index)
      end
    end

    def merge(val)
      @_lst += val
    end

    def equal?(other)
      @_lst.equal?(other)
    end

    def _yaml_add_comment(comment, key = NoComment) # checked
      if key == NoComment
        ca.comment = comment
      else
        yaml_key_comment_extend(key, comment)
      end
    end

    def _yaml_add_eol_comment(comment, key)
      _yaml_add_comment(comment, :key => key)
    end

    def _yaml_get_columnX(key)
      ca.items[key][0].start_mark.column
    end

    def _yaml_get_column(key)
      column = nil
      sel_idx = nil
      pre = key - 1
      post = key + 1
      if ca.items.include?(pre)
        sel_idx = pre
      elsif ca.items.include?(post)
        sel_idx = post
      else
        # ca.items is not ordered
        self.each do |row_idx, _k1|
          break if row_idx >= key
          next unless ca.items.include?(row_idx)
          sel_idx = row_idx
        end
      end
      if sel_idx
      column = _yaml_get_columnX(sel_idx)
      end
      column
    end

    def _yaml_get_pre_comment
      pre_comments = []
      if ca.comment
        pre_comments = ca.comment[1]
      else
        ca.comment = [nil, pre_comments]
      end
      pre_comments
    end

    def _yaml_clear_pre_comment
      pre_comments = []
      if ca.comment
        ca.comment[1] = pre_comments
      else
        ca.comment = [nil, pre_comments]
      end
      pre_comments
    end

    def deep_dup(_memo)
      res = self.class.new
      # _memo[id] = res
      self.each do |k|
        res.append(k.deep_dup) #, _memo)
        copy_attributes(res) #, :memo => _memo)
      end
      res
    end

    def __add__(other)
      @_lst.__add__(other)
    end

    def sort(key = nil, reverse = false)
      if key
        tmp_lst = @_lst.map(key).zip((0..size).to_a).sort.reverse
        tmp_lst.each { |x| @_lst << @_lst.fetch(x[1]) }
      else
        tmp_lst = self.zip((0..size).to_a).sort.reverse
        tmp_lst.each { |x| @_lst << @_lst.fetch(x[0]) }
      end
      itm = ca.items
      ca._items = {}
      tmp_lst.each do |idx, x|
        old_index = x[1]
        if itm.include?(old_index)
          ca.items[idx] = itm[old_index]
        end
      end
    end

    def to_s
      @_lst.to_s
    end
  end


  class CommentedKeySeq#(tuple, CommentedBase)
    "This primarily exists to be able to roundtrip keys that are sequences"

    def _yaml_add_comment(comment, key = NoComment) # checked
      if key == NoComment
        ca.comment = comment
      else
        yaml_key_comment_extend(key, comment)
      end
    end

    def _yaml_add_eol_comment(comment, key)
      _yaml_add_comment(comment, :key => key)
    end

    def _yaml_get_columnX(key)
      ca.items[key][0].start_mark.column
    end

    def _yaml_get_column(key)
      column = nil
      sel_idx = nil
      pre = key - 1
      post = key + 1
      if ca.items.include?(pre)
        sel_idx = pre
      elsif ca.items.include?(post)
        sel_idx = post
      else
        # ca.items is not ordered
        each do |row_idx, _k1|
          break if row_idx >= key

          next unless ca.items.include?(row_idx)

          sel_idx = row_idx
        end
      end
      column = _yaml_get_columnX(sel_idx) if sel_idx
      column
    end

    def _yaml_get_pre_comment
      pre_comments = []
      if ca.comment
        pre_comments = ca.comment[1]
      else
        ca.comment = [nil, pre_comments]
      end
      pre_comments
    end

    def _yaml_clear_pre_comment
      pre_comments = []
      if ca.comment
        ca.comment[1] = pre_comments
      else
        ca.comment = [nil, pre_comments]
      end
      pre_comments
    end
  end

  class CommentedMapView
    attr_accessor :_mapping

    def initialize(mapping)
      @_mapping = mapping
    end

    def size
      @_mapping.size
    end
    alias :length :size
  end


  class CommentedMapKeysView#(CommentedMapView, Set)
    def self._from_iterable(it)
      Set.new(it)
    end

    def include?(key)
      @_mapping.include?(key)
    end

    def each
      @_mapping.each { |x| yield x }
    end
  end


  class CommentedMapItemsView#(CommentedMapView, Set)
    def self._from_iterable(it)
      Set.new(it)
    end

    def incle?(item)
      key, value = item
      begin
        v = @_mapping[key]
      rescue KeyError
        return false
      end
      v == value
    end

    def each
      @_mapping.each_key { |key| yield [key, @_mapping[key]] }
    end
  end


  class CommentedMapValuesView < CommentedMapView
    def include?(value)
      @_mapping.each_key { |key| return true if value == @_mapping[key] }
      false
    end

    def each
      @_mapping.each_key { |key| yield @_mapping[key] }
    end
  end


  class CommentedMap < CommentedBase
    attr_accessor Comment.attrib.to_sym, :_ok, :_ref

    def initialize(*args, **kw)
      @_ok = Set.new
      @_ref = []
      @ordereddict = Hash[args]
    end

    def _yaml_add_comment(comment, key = NoComment, value = NoComment) # checked
      "values is set to key to indicate a value attachment of comment"
      unless key == NoComment
        yaml_key_comment_extend(key, comment)
        return
      end
      if value == NoComment
        ca.comment = comment
      else
        yaml_value_comment_extend(value, comment)
      end
    end

    def _yaml_add_eol_comment(comment, key)
      "add on the value line, with value specified by the key"
      _yaml_add_comment(comment, :value => key)
    end

    def _yaml_get_columnX(key)
      ca[key][2].start_mark.column
    end

    def _yaml_get_column(key)
      column = nil
      sel_idx = nil
      pre = nil
      post = nil
      last = nil
      self.each do |x|
        if pre && x != key
          post = x
          break
        end
        pre = last if x == key
        last = x
      end
      if ca.has_key?(pre)
        sel_idx = pre
      elsif ca.has_key?(post)
        sel_idx = post
      else
        # ca.items is not ordered
        self.each do |k1|
          break if k1 >= key
          next unless ca.has_key?(k1)
          sel_idx = k1
        end
      end
      column = _yaml_get_columnX(sel_idx) if sel_idx
      column
    end

    def _yaml_get_pre_comment
      pre_comments = []
      if ca.comment
        pre_comments = ca.comment[1]
      else
        ca.comment = [nil, pre_comments]
      end
      pre_comments
    end

    def _yaml_clear_pre_comment
      pre_comments = []
      if ca.comment
        ca.comment[1] = pre_comments
      else
        ca.comment = [nil, pre_comments]
      end
      pre_comments
    end

    def update(*vals, **kw)
      begin
        @ordereddict.merge(*vals, **kw)
      rescue TypeError
        # probably a dict that is used
        vals[0].each { |x| @ordereddict[x] = vals[0][x] }
      end
      if vals
        begin
          @_ok.merge(vals[0].keys)
        rescue AttributeError
          # assume one argument that is a list/tuple of two element lists/tuples
          vals[0].each { |x| @_ok.add(x[0]) }
        end
      end
      @_ok.merge(*kw.keys) if kw
    end

    def insert(pos, key, value, comment = nil)
      "insert key value into given position
        attach comment if provided
        "
      keys = self.keys.append(key)
      @ordereddict.insert(pos, key, value) # specifying pos is not a thing Ruby Hash can do
      @_ok.merge(keys)
      @_ref.each do |referer|
        keys.each { |keytmp| referer.update_key_value(keytmp) }
      end
      yaml_add_eol_comment(comment, :key => key) if comment
    end

    # Never used except in the tests; use Hash#dig instead:
    # def mlget(key, default=nil, list_ok=false)
    #     # type: (Any, Any, Any) -> Any
    #     """multi-level get that expects dicts within dicts"""
    #     if not isinstance(key, list)
    #         return get(key, default)
    #     # assume that the key is a list of recursively accessible dicts
    #
    #     def get_one_level(key_list, level, d)
    #         # type: (Any, Any, Any) -> Any
    #         if not list_ok
    #             assert isinstance(d, dict)
    #         if level >= len(key_list)
    #             if level > len(key_list)
    #                 raise IndexError
    #             return d[key_list[level - 1]]
    #         return get_one_level(key_list, level + 1, d[key_list[level - 1]])
    #
    #     try
    #         return get_one_level(key, 1, self)
    #     rescue KeyError
    #         return default
    #     rescue (TypeError, IndexError)
    #         if not list_ok
    #             raise
    #         return default

    def [](key)
      begin
        return @ordereddict[key]
      rescue KeyError
        (merge_attrib || []).each { |merged| return merged[1][key] if merged[1].has_key?(key) }
        raise
      end
    end

    def []=(key, value)
      # begin to preserve the scalarstring type if setting an existing key to a new value
      if self.has_key?(key)
        if value.instance_of?(String) &&
          self[key].instance_of?(ScalarString)
        value = self[key].class.new(value) end
      end
      @ordereddict[key] = value
      @_ok.add(key)
    end

    def _unmerged_contains(key)
      @_ok.include?(key)
    end

    def include?(key)
      @ordereddict.has_key?(key)
    end

    def get(key, default = nil)
      begin
        return self[key]
      rescue
        return default
      end
    end

    def to_s
      @ordereddict.to_s.sub('CommentedMap', 'ordereddict')
    end

    def non_merged_items
      @ordereddict.__iter__each do |x|
        if @_ok.include?(x)
          yield x, @ordereddict[x]
        end
      end
    end

    def delete(key)
      @_ok.delete(key)
      @ordereddict.delete(key)
      @_ref.each { |referrer| referrer.update_key_value(key) }
    end

    def each
      @ordereddict.each_key { |x| yield x }
    end
    alias :_keys :each

    def size
      @ordereddict.size
    end
    alias :length :size

    def equal?(other)
      dict == other
    end

    def keys
      CommentedMapKeysView.new(self)
    end

    def values
      CommentedMapValuesView.new(self)
    end

    def _items
      @ordereddict.each { |k, v| yield k, v }
    end

    def items
      CommentedMapItemsView.new(self)
    end

    def _merge
      @merge_attrib = [] unless defined?(@merge_attrib)
      @merge_attrib
    end

    # def copy
        # x = type()  # update doesn't work
        # for k, v in _items()
        #     x[k] = v
        # copy_attributes(x)
        # return x
    alias :copy :dup

    def add_referent(cm) # checked
      @_ref.append(cm) unless @_ref.include?(cm)
    end

    def add_yaml_merge(value) # checked
      value.each do |v|
        v[1].add_referent
        v[1].each do |k, v|
          next if @ordereddict.has_key?(k)

          @ordereddict[k] = v
        end
      end
      _merge += value # I hope this is correct. - ADC
    end

    def update_key_value(key)
      return if @_ok.include?(key)
      _merge.each do |v|
        if v[1].include?(key)
          @ordereddict[key] = v[1][key]
          return
        end
      end
      @ordereddict.delete(key)
    end

    # def __deepcopy__(memo)
    #     # type: (Any) -> Any
    #     res = __class__()
    #     memo[id] = res
    #     for k in self
    #         res[k] = copy.deepcopy(self[k], memo)
    #     copy_attributes(res, memo=memo)
    #     return res
    def deep_dup
      res = self.class.new
      self.each do |k|
        res[x] = self[k].deep_dup
      end
      res
    end
  end

# based on brownie mappings
# @classmethod
# def raise_immutable(cls, *args, **kwargs)
#     raise TypeError.new('{} objects are immutable'.format(cls.__name__))
# end


  class CommentedKeyMap#CommentedBase, Mapping
    attr_accessor Comment.attrib.to_sym, :_od
    "This primarily exists to be able to roundtrip keys that are mappings"

    def initialize(*args, **kw)
      raise_immutable if defined?(@_od)
      begin
        @_od = ordereddict.new(*args, **kw)
      rescue TypeError
        raise
      end
    end

    def self.raise_immutable(*args, **kwargs)
      raise TypeError.new("{name} objects are immutable")
    end
    def raise_immutable(*args, **kwargs)
      self.class.raise_immutable(*args, **kwargs)
    end

    alias :delete :raise_immutable
    alias :[]= :raise_immutable
    alias :clear :raise_immutable
    alias :pop :raise_immutable
    alias :popitem :raise_immutable
    alias :setdefault :raise_immutable
    alias :update :raise_immutable

    # need to implement __getitem__, __iter__ and __len__
    def [](index)
      @_od[index]
    end

    def each
      @_od.each { |x| yield x }
    end

    def size
      @_od.size
    end
    alias :length :size

    def __hash__
      hash(to_a)
    end

    def to_s
      return @_od.to_s unless defined?(@merge_attrib)

      'ordereddict(' + repr(list(_od.items())) + ')'
    end

    def self.fromkeys(keys, v = nil)
      h = {}
      keys.each { |key| h[key] = v }
      CommentedKeyMap.new(h)
    end

    def _yaml_add_comment(comment, key = NoComment) # checked
      if key == NoComment
        ca.comment = comment
      else
        yaml_key_comment_extend(key, comment)
      end
    end

    def _yaml_add_eol_comment(comment, key)
      _yaml_add_comment(comment, :key => key)
    end

    def _yaml_get_columnX(key)
        ca[key][0].start_mark.column
    end

    def _yaml_get_column(key)
      column = nil
      sel_idx = nil
      pre = key - 1
      post = key + 1
      if ca.has_key?(pre)
        sel_idx = pre
      elsif ca.has_key?(post)
        sel_idx = post
      else
        # ca.items is not ordered
        self.each do |row_idx, _k1|
          break if row_idx >= key
          next unless ca.items.has_key?(row_idx)
          sel_idx = row_idx
        end
        column = _yaml_get_columnX(sel_idx) if sel_idx
        column
      end
    end

    def _yaml_get_pre_comment
      pre_comments = []
      if ca.comment
        ca.comment = [nil, pre_comments]
      else
        ca.comment[1] = pre_comments
      end
      pre_comments
    end
  end


  class CommentedOrderedMap < CommentedMap
    attr_accessor Comment.attrib.to_sym
  end


  class CommentedSet#(MutableSet, CommentedBase)
    attr_accessor Comment.attrib.to_sym, :odict

    def initialize(other_set = nil)
      @odict = Hash.new
      @mutable_set = Set.new
      @mutable_set |= other_set if other_set
    end

    def _yaml_add_comment(comment, key = NoComment, value = NoComment) # checked
      "values is set to key to indicate a value attachment of comment"
      unless key == NoComment
        yaml_key_comment_extend(key, comment)
        return
      end
      if value == NoComment
        ca.comment = comment
      else
        yaml_value_comment_extend(value, comment)
      end
    end

    def _yaml_add_eol_comment(comment, key)
      "add on the value line, with value specified by the key"
      _yaml_add_comment(comment, :value => key)
    end

    def add(value)
      "Add an element."
      @odict[value] = nil
    end

    def discard(value)
      "Remove an element.  Do not raise an exception if absent."
      odict.delete(value)
    end

    def include?(x)
      @odict.include?(x)
    end

    def each
        @odict.keys.each { |x| yield x }
    end

    def size
      @odict.size
    end
    alias :length :size

    def to_s
        'set({0!r})'.format(@odict.keys)
    end
  end


  class TaggedScalar < CommentedBase
    # the value and style attributes are set during roundtrip construction
    def initialize(value = nil, style = nil, tag = nil)
      @value = value
      @style = style
      yaml_set_tag(tag) if tag
    end

    def to_str
      @value
    end
  end
end


=begin
def dump_comments(d, name="", sep='.', out=sys.stdout)
    "
    recursively dump comments, all but the toplevel preceded by the path
    in dotted form x.0.a
    "
    if isinstance(d, dict) and hasattr(d, 'ca')
        if name
            out.write('{} {}\n'.format(name, type(d)))
        out.write('{!r}\n'.format(d.ca))  # type: ignore
        for k in d
            dump_comments(d[k], name=(name + sep + str(k)) if name else k, sep=sep, out=out)
    elsif isinstance(d, list) and hasattr(d, 'ca')
        if name
            out.write('{} {}\n'.format(name, type(d)))
        out.write('{!r}\n'.format(d.ca))  # type: ignore
        for idx, k in enumerate(d)
            dump_comments(
                k, name=(name + sep + str(idx)) if name else str(idx), sep=sep, out=out
            )
=end
