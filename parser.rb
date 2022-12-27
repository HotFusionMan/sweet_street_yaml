# encoding: utf-8

# frozen_string_literal: true

# The following YAML grammar is LL(1) and is parsed by a recursive descent
# parser.
#
# stream            ::= STREAM-START implicit_document? explicit_document*
#                                                                   STREAM-END
# implicit_document ::= block_node DOCUMENT-END*
# explicit_document ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*
# block_node_or_indentless_sequence ::=
#                       ALIAS
#                       | properties (block_content |
#                                                   indentless_block_sequence)?
#                       | block_content
#                       | indentless_block_sequence
# block_node        ::= ALIAS
#                       | properties block_content?
#                       | block_content
# flow_node         ::= ALIAS
#                       | properties flow_content?
#                       | flow_content
# properties        ::= TAG ANCHOR? | ANCHOR TAG?
# block_content     ::= block_collection | flow_collection | SCALAR
# flow_content      ::= flow_collection | SCALAR
# block_collection  ::= block_sequence | block_mapping
# flow_collection   ::= flow_sequence | flow_mapping
# block_sequence    ::= BLOCK-SEQUENCE-START (BLOCK-ENTRY block_node?)*
#                                                                   BLOCK-END
# indentless_sequence   ::= (BLOCK-ENTRY block_node?)+
# block_mapping     ::= BLOCK-MAPPING_START
#                       ((KEY block_node_or_indentless_sequence?)?
#                       (VALUE block_node_or_indentless_sequence?)?)*
#                       BLOCK-END
# flow_sequence     ::= FLOW-SEQUENCE-START
#                       (flow_sequence_entry FLOW-ENTRY)*
#                       flow_sequence_entry?
#                       FLOW-SEQUENCE-END
# flow_sequence_entry   ::= flow_node | KEY flow_node? (VALUE flow_node?)?
# flow_mapping      ::= FLOW-MAPPING-START
#                       (flow_mapping_entry FLOW-ENTRY)*
#                       flow_mapping_entry?
#                       FLOW-MAPPING-END
# flow_mapping_entry    ::= flow_node | KEY flow_node? (VALUE flow_node?)?
#
# FIRST sets:
#
# stream: { STREAM-START <}
# explicit_document: { DIRECTIVE DOCUMENT-START }
# implicit_document: FIRST(block_node)
# block_node: { ALIAS TAG ANCHOR SCALAR BLOCK-SEQUENCE-START
#                  BLOCK-MAPPING-START FLOW-SEQUENCE-START FLOW-MAPPING-START }
# flow_node: { ALIAS ANCHOR TAG SCALAR FLOW-SEQUENCE-START FLOW-MAPPING-START }
# block_content: { BLOCK-SEQUENCE-START BLOCK-MAPPING-START
#                               FLOW-SEQUENCE-START FLOW-MAPPING-START SCALAR }
# flow_content: { FLOW-SEQUENCE-START FLOW-MAPPING-START SCALAR }
# block_collection: { BLOCK-SEQUENCE-START BLOCK-MAPPING-START }
# flow_collection: { FLOW-SEQUENCE-START FLOW-MAPPING-START }
# block_sequence: { BLOCK-SEQUENCE-START }
# block_mapping: { BLOCK-MAPPING-START }
# block_node_or_indentless_sequence: { ALIAS ANCHOR TAG SCALAR
#               BLOCK-SEQUENCE-START BLOCK-MAPPING-START FLOW-SEQUENCE-START
#               FLOW-MAPPING-START BLOCK-ENTRY }
# indentless_sequence: { ENTRY }
# flow_collection: { FLOW-SEQUENCE-START FLOW-MAPPING-START }
# flow_sequence: { FLOW-SEQUENCE-START }
# flow_mapping: { FLOW-MAPPING-START }
# flow_sequence_entry: { ALIAS ANCHOR TAG SCALAR FLOW-SEQUENCE-START
#                                                    FLOW-MAPPING-START KEY }
# flow_mapping_entry: { ALIAS ANCHOR TAG SCALAR FLOW-SEQUENCE-START
#                                                    FLOW-MAPPING-START KEY }

require_relative './sweet_street_yaml'
require_relative './error' # MarkedYAMLError
require_relative './tokens'
require_relative './events'
require_relative './scanner' # Scanner, RoundTripScanner, ScannerError BlankLineComment
require_relative './comments' # C_PRE, C_POST, C_SPLIT_ON_FIRST_BLANK
# require_relative './compat' # _F, nprint, nprintf


module SweetStreetYaml
  MINIMUM_YAML_VERSION = VERSION_1_1

  class ParserError < MarkedYAMLError
  end

  class Parser
    DEFAULT_TAGS = { '!' => '!', '!!' => 'tag:yaml.org,2002:' }.freeze

    attr_accessor :_parser

    def initialize(loader) # checked
      @loader = loader
      if @loader && @loader._parser.nil?
        @loader._parser = self
      end
      reset_parser
    end

    def reset_parser # checked
      # Reset the state attributes (to clear self-references)
      @current_event = @last_event = nil
      @tag_handles = {}
      @states = []
      @marks = []
      @state = method(:parse_stream_start)
    end

    def dispose
      reset_parser
    end

    def scanner
      return(@scanner) if defined?(@scanner)

      return(@scanner = @loader.scanner) if @loader.respond_to?(:typ)

      @scanner = @loader._scanner
    end

    def resolver
      return(@resolver) if defined?(@resolver)

      return(@resolver = @loader.resolver) if @loader.respond_to?(:typ)

      @resolver = @loader._resolver
    end

    def check_event(*choices)
      if @current_event.nil?
        if @state
          @current_event = @state.call
        end
      end

      if @current_event
        return true if choices.empty?

        choices.each { |choice| return true if @current_event.instance_of?(choice) }
      end

      false
    end

    def peek_event
      if @current_event.nil?
        if @state
          @current_event = @state.call
        end
      end
      @current_event
    end

    def get_event
      if @current_event.nil?
        if @state
          @current_event = @state.call
        end
      end
      @last_event = @current_event
      @current_event = nil
      @last_event
    end

    # stream    ::= STREAM-START implicit_document? explicit_document*
    #                                                               STREAM-END
    # implicit_document ::= block_node DOCUMENT-END*
    # explicit_document ::= DIRECTIVE* DOCUMENT-START block_node? DOCUMENT-END*

    def parse_stream_start # checked
      token = scanner.get_token
      move_token_comment(token)
      event = StreamStartEvent.new(:start_mark => token.start_mark, :end_mark => token.end_mark, :encoding => token.encoding)

      # Prepare the next state.
      @state = method(:parse_implicit_document_start)

      event
    end

    def parse_implicit_document_start # checked
      if scanner.check_token(DirectiveToken, DocumentStartToken, StreamEndToken)
        return parse_document_start
      else
        @tag_handles = DEFAULT_TAGS
        token = @scanner.peek_token
        start_mark = end_mark = token.start_mark
        event = DocumentStartEvent.new(:start_mark => start_mark, :end_mark => end_mark, :explicit => false)

        # Prepare the next state.
        @states.append(method(:parse_document_end))
        @state = method(:parse_block_node)

        event
      end
    end

    def parse_document_start # checked
      # Parse any extra document end indicators.
      while @scanner.check_token(DocumentEndToken)
        @scanner.get_token
      end
      # Parse an explicit document.
      if @scanner.check_token(StreamEndToken)
        # Parse the end of the stream.
        token = @scanner.get_token
        event = StreamEndEvent.new(token.start_mark, token.end_mark, comment=token.comment)
        raise '@states not empty' unless @states.empty?
        raise '@marks not empty' unless @marks.empty?
        @state = nil
      else
        version, tags = process_directives
        unless scanner.check_token(DocumentStartToken)
          peek_token = scanner.peek_token
          raise ParserError.new(
            nil,
            nil,
            _F(
              "expected '<document start>', but found {pt!r}",
              pt = peek_token.id,
              ),
            peek_token.start_mark
          )
        end
        token = @scanner.get_token
        start_mark = token.start_mark
        end_mark = token.end_mark
        event = DocumentStartEvent.new(
          :start_mark => start_mark,
          :end_mark => end_mark,
          :explicit => true,
          :version => version,
          :tags => tags,
          :comment => token.comment
        )
        @states.append(method(:parse_document_end))
        @state = method(:parse_document_content)
      end
      event
    end

    def parse_document_end # checked
      # Parse the document end.
      token = @scanner.peek_token
      start_mark = end_mark = token.start_mark
      explicit = false
      if @scanner.check_token(DocumentEndToken)
        token = @scanner.get_token
        end_mark = token.end_mark
        explicit = true
      end
      event = DocumentEndEvent.new(:start_mark => start_mark, :end_mark => end_mark, :explicit => explicit)

      # Prepare the next state.
      if resolver.processing_version == VERSION_1_1
        @state = method(:parse_document_start)
      else
        @state = method(:parse_implicit_document_start)
      end

      event
    end

    def parse_document_content # checked
      if @scanner.check_token(DirectiveToken, DocumentStartToken, DocumentEndToken, StreamEndToken)
        event = process_empty_scalar(@scanner.peek_token.start_mark)
        @state = @states.pop
        return event
      else
        parse_block_node
      end
    end

    def process_directives
      yaml_version = nil
      @tag_handles = {}
      while @scanner.check_token(DirectiveToken)
        token = @scanner.get_token
        case token.name
          when 'YAML'
            raise ParserError.new(nil, nil, 'found duplicate YAML directive', token.start_mark) if yaml_version

            major, minor = token.value
            unless major == 1
              raise ParserError.new(
                nil,
                nil,
                'found incompatible YAML document (version 1.* is required)',
                token.start_mark
                )
            end
            yaml_version = token.value
          when 'TAG'
            handle, prefix = token.value
            if @tag_handles.has_key?(handle)
              raise ParserError.new(
                nil,
                nil,
                _F('duplicate tag handle {handle!r}', handle=handle),
                token.start_mark,
                )
            end
            @tag_handles[handle] = prefix
        end
      end

      if @tag_handles.empty?
        value = [yaml_version, nil]
      else
        value = [yaml_version, @tag_handles.dup]
      end

      if @loader.respond_to?(:tags)
        @loader.version = yaml_version
        @loader.tags ||= {}
        # @tag_handles.each_key { |k| @loader.tags[k] = @tag_handles[k]  }
        @loader.tags.merge!(@tag_handles)
      end
      DEFAULT_TAGS.each { |key| @tag_handles[key] = DEFAULT_TAGS[key] unless @tag_handles.has_key?(key) }
      value
    end

    # block_node_or_indentless_sequence ::= ALIAS
    #               | properties (block_content | indentless_block_sequence)?
    #               | block_content
    #               | indentless_block_sequence
    # block_node    ::= ALIAS
    #                   | properties block_content?
    #                   | block_content
    # flow_node     ::= ALIAS
    #                   | properties flow_content?
    #                   | flow_content
    # properties    ::= TAG ANCHOR? | ANCHOR TAG?
    # block_content     ::= block_collection | flow_collection | SCALAR
    # flow_content      ::= flow_collection | SCALAR
    # block_collection  ::= block_sequence | block_mapping
    # flow_collection   ::= flow_sequence | flow_mapping

    def parse_block_node # checked
      parse_node(true)
    end

    # Declared via alias of parse_node:
    # def parse_flow_node
    #   parse_node
    # end

    def parse_block_node_or_indentless_sequence # checked
      parse_node(true, true)
    end

    def transform_tag(handle, suffix)
      @tag_handles[handle] + suffix
    end

    def parse_node(block = false, indentless_sequence = false) # checked
      if @scanner.check_token(AliasToken)
        token = @scanner.get_token
        event = AliasEvent.new(:anchor => token.value, :start_mark => token.start_mark, :end_mark => token.end_mark)
        @state = @states.pop
        return event
      end

      anchor = tag = start_mark = end_mark = tag_mark = nil
      if @scanner.check_token(AnchorToken)
        token = @scanner.get_token
        move_token_comment(token)
        start_mark = token.start_mark
        end_mark = token.end_mark
        anchor = token.value
        if @scanner.check_token(TagToken)
          token = @scanner.get_token
          tag_mark = token.start_mark
          end_mark = token.end_mark
          tag = token.value
        end
      elsif @scanner.check_token(TagToken)
        token = @scanner.get_token
        start_mark = tag_mark = token.start_mark
        end_mark = token.end_mark
        tag = token.value
        if @scanner.check_token(AnchorToken)
          token = @scanner.get_token
          start_mark = tag_mark = token.start_mark
          end_mark = token.end_mark
          anchor = token.value
        end
      end
      if tag
        handle, suffix = tag
        if handle
          unless @tag_handles.has_key?(handle)
            raise ParserError.new(
              'while parsing a node',
              start_mark,
              _F('found undefined tag handle {handle!r}', handle=handle),
              tag_mark,
              )
          end
          tag = transform_tag(handle, suffix)
        else
          tag = suffix
        end
      end

      if start_mark.nil?
        start_mark = end_mark = @scanner.peek_token.start_mark
      end
      event = nil
      implicit = tag.nil? || (tag == '!')
      if indentless_sequence && @scanner.check_token(BlockEntryToken)
        comment = nil
        pt = @scanner.peek_token
        if @loader && @loader.comment_handling.nil?
          if pt&.comment[0]
            comment = [pt.comment[0], []]
            pt.comment[0] = nil
          end
        elsif @loader
          if pt.comment
            comment = pt.comment
          end
        end
        end_mark = @scanner.peek_token.end_mark
        event = SequenceStartEvent.new(
          anchor, tag, implicit, :start_mark => start_mark, :end_mark => end_mark, :flow_style => false, :comment => comment
        )
        @state = method(:parse_indentless_sequence_entry)
        return event
      end

      if @scanner.check_token(ScalarToken)
        token = @scanner.get_token
        end_mark = token.end_mark
        if (token.plain && tag.nil?) || tag == '!'
          implicit = [true, false]
        elsif tag.nil?
          implicit = [false, true]
        else
          implicit = [false, false]
        end
        event = ScalarEvent.new(
          :anchor => anchor,
          :tag => tag,
          :implicit => implicit,
          :value => token.value,
          :start_mark => start_mark,
          :end_mark => end_mark,
          :style => token.style,
          :comment => token.comment
          )
        @state = @states.pop
      elsif @scanner.check_token(FlowSequenceStartToken)
        pt = @scanner.peek_token
        end_mark = pt.end_mark
        event = SequenceStartEvent.new(
          anchor,
          tag,
          implicit,
          :start_mark => start_mark,
          :end_mark => end_mark,
          :flow_style => true,
          :comment => pt.comment
          )
        @state = method(:parse_flow_sequence_first_entry)
      elsif @scanner.check_token(FlowMappingStartToken)
        pt = @scanner.peek_token
        end_mark = pt.end_mark
        event = MappingStartEvent.new(
          anchor,
          tag,
          implicit,
          :start_mark => start_mark,
          :end_mark => end_mark,
          :flow_style => true,
          :comment => pt.comment
          )
        @state = method(:parse_flow_mapping_first_key)
      elsif block && @scanner.check_token(BlockSequenceStartToken)
        end_mark = @scanner.peek_token.start_mark
        pt = @scanner.peek_token
        comment = pt.comment
        if comment.nil? || comment[1].nil?
          comment = pt.split_old_comment
        end
        event = SequenceStartEvent.new(:anchor => anchor, :tag => tag, :implicit => implicit, :start_mark => start_mark, :end_mark => end_mark, :flow_style => false, :comment => comment)
        @state = method(:parse_block_sequence_first_entry)
      elsif block && @scanner.check_token(BlockMappingStartToken)
        pt = @scanner.peek_token
        end_mark = pt.start_mark
        comment = pt.comment
        event = MappingStartEvent.new(:anchor => anchor, :tag => tag, :implicit => implicit, :start_mark => start_mark, :end_mark => end_mark, :flow_style => alse, :comment => comment)
        @state = method(:parse_block_mapping_first_key)
      elsif anchor || tag
        # Empty scalars are allowed even if a tag or an anchor is specified.
        event = ScalarEvent.new(:anchor => anchor, :tag => tag, :implicit => false, :value => '', :start_mark => start_mark, :end_mark => end_mark)
        @state = @states.pop
      else
        if block
          node = 'block'
        else
          node = 'flow'
        end
        token = @scanner.peek_token
        raise ParserError.new(
          _F('while parsing a {node!s} node', node=node),
          start_mark,
          _F('expected the node content, but found {token_id!r}', token_id=token.id),
          token.start_mark,
          )
      end
      event
    end
    alias :parse_flow_node :parse_node

    # block_sequence ::= BLOCK-SEQUENCE-START (BLOCK-ENTRY block_node?)*
    #                                                               BLOCK-END

    def parse_block_sequence_first_entry
      token = @scanner.get_token
      @marks.append(token.start_mark)
      parse_block_sequence_entry
    end

    def parse_block_sequence_entry # checked
      if @scanner.check_token(BlockEntryToken)
        token = @scanner.get_token
        move_token_comment(token)
        if @scanner.check_token(BlockEntryToken, BlockEndToken)
          @state = method(:parse_block_sequence_entry)
          return process_empty_scalar(token.end_mark)
        else
          @states.append(method(:parse_block_sequence_entry))
          return parse_block_node
        end
        unless @scanner.check_token(BlockEndToken)
          token = @scanner.peek_token
          raise ParserError.new(
            'while parsing a block collection',
            self.marks[-1],
            _F('expected <block end>, but found {token_id!r}', token_id=token.id),
            token.start_mark,
            )
        end
        token = @scanner.get_token  # BlockEndToken
        event = SequenceEndEvent.new(:start_mark => token.start_mark, :end_mark => token.end_mark, :comment => token.comment)
        @state = @states.pop
        @marks.pop
        event
      end
    end

    # indentless_sequence ::= (BLOCK-ENTRY block_node?)+

    # indentless_sequence?
    # sequence:
    # - entry
    #  - nested

    def parse_indentless_sequence_entry
      if @scanner.check_token(BlockEntryToken)
        token = @scanner.get_token
        move_token_comment(token)
        if @scanner.check_token(BlockEntryToken, KeyToken, ValueToken, BlockEndToken)
          @state = method(:parse_indentless_sequence_entry)
          return process_empty_scalar(token.end_mark)
        else
          @states.append(method(:parse_indentless_sequence_entry))
          return parse_block_node
        end
      end
      token = @scanner.peek_token
      c = nil
      if @loader && @loader.comment_handling.nil?
        c = token.comment
        start_mark = token.start_mark
      else
        start_mark = @last_event.end_mark
        c = distribute_comment(token.comment, start_mark.line)
      end
      event = SequenceEndEvent.new(:start_mark => start_mark, :end_mark => start_mark, :comment => c)
      @state = @states.pop
      event
    end

    # block_mapping     ::= BLOCK-MAPPING_START
    #                       ((KEY block_node_or_indentless_sequence?)?
    #                       (VALUE block_node_or_indentless_sequence?)?)*
    #                       BLOCK-END

    def parse_block_mapping_first_key
      token = @scanner.get_token
      @marks.append(token.start_mark)
      parse_block_mapping_key
    end

    def parse_block_mapping_key # checked
      if @scanner.check_token(KeyToken)
        token = @scanner.get_token
        move_token_comment(token)
        if @scanner.check_token(KeyToken, ValueToken, BlockEndToken)
          @states.append(method(:parse_block_mapping_value))
          return parse_block_node_or_indentless_sequence
        else
          @state = method(:parse_block_mapping_value)
          return process_empty_scalar(token.end_mark)
        end
      end
      resolver_processing_version = @resolver.processing_version
      if (resolver_processing_version > Ruamel::MINIMUM_YAML_VERSION) && @scanner.check_token(ValueToken)
        @state = method(:parse_block_mapping_value)
        return process_empty_scalar(@scanner.peek_token.start_mark)
      end
      unless @scanner.check_token(BlockEndToken)
        token = @scanner.peek_token
        raise ParserError.new(
          'while parsing a block mapping',
          @marks[-1],
          _F('expected <block end>, but found {token_id!r}', token_id=token.id),
          token.start_mark
        )
      end
      token = @scanner.get_token
      move_token_comment(token)
      event = MappingEndEvent.new(:start_mark => token.start_mark, :end_mark => token.end_mark, :comment => token.comment)
      @state = @states.pop
      @marks.pop
      event
    end

    def parse_block_mapping_value # checked
      if @scanner.check_token(ValueToken)
        token = @scanner.get_token
        # value token might have post comment move it to e.g. block
        if @scanner.check_token(ValueToken)
          move_token_comment(token)
        else
          unless @scanner.check_token(KeyToken)
            move_token_comment(token, empty=true)
          # else # empty value for this key cannot move token.comment
          end
        end
        if @scanner.check_token(KeyToken, ValueToken, BlockEndToken)
          @state = method(:parse_block_mapping_key)
          comment = token.comment
          if comment.nil?
            token = @scanner.peek_token
            comment = token.comment
            if comment
              token._comment = [nil, comment[1]]
              comment = [comment[0], nil]
            end
          end
          return process_empty_scalar(token.end_mark, comment)
        end
      else
        @state = method(:parse_block_mapping_key)
        token = @scanner.peek_token
        return process_empty_scalar(token.start_mark)
      end
    end

    # flow_sequence     ::= FLOW-SEQUENCE-START
    #                       (flow_sequence_entry FLOW-ENTRY)*
    #                       flow_sequence_entry?
    #                       FLOW-SEQUENCE-END
    # flow_sequence_entry   ::= flow_node | KEY flow_node? (VALUE flow_node?)?
    #
    # Note that while production rules for both flow_sequence_entry and
    # flow_mapping_entry are equal, their interpretations are different.
    # For `flow_sequence_entry`, the part `KEY flow_node? (VALUE flow_node?)?`
    # generate an inline mapping (set syntax).

    def parse_flow_sequence_first_entry
      token = @scanner.get_token
      @marks.append(token.start_mark)
      parse_flow_sequence_entry(true)
    end

    def parse_flow_sequence_entry(first = false)
      unless @scanner.check_token(FlowSequenceEndToken)
        unless first
          if @scanner.check_token(FlowEntryToken)
            @scanner.get_token
          else
            token = @scanner.peek_token
            raise ParserError.new(
              'while parsing a flow sequence',
              self.marks[-1],
              _F("expected ',' or ']', but got {token_id!r}", token_id=token.id),
              token.start_mark
            )
          end
        end
      end
      if @scanner.check_token(KeyToken)
        token = @scanner.peek_token
        event = MappingStartEvent.new(nil, nil, true, :start_mark => token.start_mark, :end_mark => token.end_mark, :flow_style => true)
        @state = method(:parse_flow_sequence_entry_mapping_key)
        return event
      elsif !@scanner.check_token(FlowSequenceEndToken)
        @states.append(method(:parse_flow_sequence_entry))
        return parse_flow_node
      end
      token = @scanner.get_token
      event = SequenceEndEvent.new(:start_mark => token.start_mark, :end_mark => token.end_mark, :comment => token.comment)
      @state = @states.pop
      @marks.pop
      event
    end

    def parse_flow_sequence_entry_mapping_key
      token = @scanner.get_token
      if @scanner.check_token(ValueToken, FlowEntryToken, FlowSequenceEndToken)
        @state = method(:parse_flow_sequence_entry_mapping_value)
        return process_empty_scalar(token.end_mark)
      else
        @states.append(method(:parse_flow_sequence_entry_mapping_value))
        return parse_flow_node
      end
    end

    def parse_flow_sequence_entry_mapping_value
      if @scanner.check_token(ValueToken)
        token = @scanner.get_token
        if @scanner.check_token(FlowEntryToken, FlowSequenceEndToken)
          @state = method(:parse_flow_sequence_entry_mapping_end)
          return process_empty_scalar(token.end_mark)
        else
          @states.append(method(:parse_flow_sequence_entry_mapping_end))
          return parse_flow_node
        end
      else
        @state = method(:parse_flow_sequence_entry_mapping_end)
        token = @scanner.peek_token
        return process_empty_scalar(token.start_mark)
      end
    end

    def parse_flow_sequence_entry_mapping_end
      @state = method(:parse_flow_sequence_entry)
      token = @scanner.peek_token
      MappingEndEvent.new(:start_mark => token.start_mark, :end_mark => token.start_mark)
    end

    # flow_mapping  ::= FLOW-MAPPING-START
    #                   (flow_mapping_entry FLOW-ENTRY)*
    #                   flow_mapping_entry?
    #                   FLOW-MAPPING-END
    # flow_mapping_entry    ::= flow_node | KEY flow_node? (VALUE flow_node?)?

    def parse_flow_mapping_first_key
      token = @scanner.get_token
      @marks.append(token.start_mark)
      parse_flow_mapping_key(true)
    end

    def parse_flow_mapping_key(first = false) # checked
      unless @scanner.check_token(FlowMappingEndToken)
        unless first
          if @scanner.check_token(FlowEntryToken)
            @scanner.get_token
          else
            token = @scanner.peek_token
            raise ParserError.new(
                    'while parsing a flow mapping',
                    @marks[-1],
                    _F("expected ',' or '}}', but got {token_id!r}", token_id=token.id),
                    token.start_mark
                  )
          end
        end
        resolver_processing_version = @resolver.processing_version
        if @scanner.check_token(KeyToken)
          token = @scanner.get_token
          if @scanner.check_token(ValueToken, FlowEntryToken, FlowMappingEndToken)
            @state = method(:parse_flow_mapping_value)
            return process_empty_scalar(token.end_mark)
          else
            @states.append(method(:parse_flow_mapping_value))
            return parse_flow_node
          end
        elsif (resolver_processing_version > Ruamel::MINIMUM_YAML_VERSION) && @scanner.check_token(ValueToken)
          @state = method(:parse_flow_mapping_value)
          return process_empty_scalar(@scanner.peek_token.end_mark)
        elsif !@scanner.check_token(FlowMappingEndToken)
          @states.append(method(:parse_flow_mapping_empty_value))
          return parse_flow_node
        end
      end
      token = @scanner.get_token
      event = MappingEndEvent.new(:start_mark => token.start_mark, :end_mark => token.end_mark, :comment => token.comment)
      @state = @states.pop
      @marks.pop
      event
    end

    def parse_flow_mapping_value # checked
      if @scanner.check_token(ValueToken)
        token = @scanner.get_token
        if @scanner.check_token(FlowEntryToken, FlowMappingEndToken)
          @state = method(:parse_flow_mapping_key)
          return process_empty_scalar(token.end_mark)
        else
          @states.append(method(:parse_flow_mapping_key))
          return parse_flow_node
        end
      else
        @state = method(:parse_flow_mapping_key)
        token = @scanner.peek_token
        return process_empty_scalar(token.start_mark)
      end
    end

    def parse_flow_mapping_empty_value # checked
      @state = method(:parse_flow_mapping_key)
      process_empty_scalar(@scanner.peek_token.start_mark)
    end

    def process_empty_scalar(mark, comment = nil) # checked
      ScalarEvent.new(:anchor => nil, :tag => nil, :implicit => [true, false], :value => '', :start_mark => mark, :end_mark => mark, :comment => comment)
    end

    def move_token_comment(token, nt = nil, empty = false)
    end
  end

  class RoundTripParser < Parser
    # roundtrip is a safe loader, that wants to see the unmangled tag

    TAGS = [
      'null',
      'bool',
      'int',
      'float',
      'binary',
      'timestamp',
      'omap',
      'pairs',
      'set',
      'str',
      'seq',
      'map'
    ].freeze

    def transform_tag(handle, suffix)
      if handle == '!!' && TAGS.include?(suffix)
        return super
      end
      handle + suffix
    end

    def move_token_comment(token, nt = nil, empty = false)
      token.move_old_comment(nt ? nt : @scanner.peek_token, empty)
    end
  end

  class RoundTripParserSC < RoundTripParser
    # roundtrip is a safe loader, that wants to see the unmangled tag

    # some of the differences are based on the superclass testing
    # if self.loader.comment_handling is not None

    def move_token_comment(token, nt = nil, empty = false)
      token.move_new_comment(nt ? nt : @scanner.peek_token, empty)
    end

    def distribute_comment(comment, line)
      return unless comment&[0]
      raise "'comment[0][0]' is '#{comment[0][0]}'" unless comment[0][0] == line + 1
      typ = @loader.comment_handling & 0b11
      case typ
        when C_POST
          return
        when C_PRE
          c = [nil, nil, comment[0]]
          comment[0] = nil
          return c
      end
      found_blank = false
      idx = 0
      comment[0].each do |cmntidx|
        if @scanner.comments[cmntidx].instance_of?(BlankLineComment)
          found_blank = true
          break
        end
        idx += 1
      end
      return unless found_blank # no space found
      return if idx == 0 # first line was blank

      if typ == C_SPLIT_ON_FIRST_BLANK
        c = [nil, nil, comment[0][0..idx]]
        comment[0] = comment[0][idx..-1]
        return c
      end
      raise NotImplementedError  # reserved
    end
  end
end
