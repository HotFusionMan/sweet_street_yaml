# frozen_string_literal: true

# Scanner produces tokens of the following types:
# STREAM-START
# STREAM-END
# DIRECTIVE(name, value)
# DOCUMENT-START
# DOCUMENT-END
# BLOCK-SEQUENCE-START
# BLOCK-MAPPING-START
# BLOCK-END
# FLOW-SEQUENCE-START
# FLOW-MAPPING-START
# FLOW-SEQUENCE-END
# FLOW-MAPPING-END
# BLOCK-ENTRY
# FLOW-ENTRY
# KEY
# VALUE
# ALIAS(value)
# ANCHOR(value)
# TAG(value)
# SCALAR(value, plain, style)
#
# RoundTripScanner
# COMMENT(value)
#
# Read comments in the Scanner code for more details.

require_relative './numeric_extensions'

require_relative './error'
require_relative './tokens'
require_relative './compat'

module SweetStreetYaml
  class SimpleKey
    # See below simple keys treatment.
    def initialize(token_number, required, index, line, column, mark)
      @token_number = token_number
      @required = required
      @index = index
      @line = line
      @column = column
      @mark = mark
    end

    attr_reader :token_number, :required, :index, :line, :column, :mark
  end

  class Scanner
    using NumericExtensions

    ASCII_LINE_ENDING = "\r\n\u{9b}"
    UNICODE_LINE_ENDING = "\u2028\u2029"
    LINE_ENDING = (ASCII_LINE_ENDING + UNICODE_LINE_ENDING).freeze
    LINE_ENDINGS_REGEXP = Regexp.new(LINE_ENDING)
    LINE_ENDING_SPACE = (LINE_ENDING + ' ').freeze
    THE_END = (LINE_ENDING + "\0").freeze
    THE_END_SPACE = (THE_END + ' ').freeze
    THE_END_SPACE_QUOTE_BACKSLASH = (THE_END_SPACE + "\"'\\").freeze
    SPACE_TAB = " \t"
    THE_END_SPACE_TAB = (THE_END + SPACE_TAB).freeze
    THE_END_SPACE_TAB_COMMA_BRACKETS = (THE_END_SPACE_TAB + ',[]{}').freeze
    DIGITS = ('0'..'9').to_a.freeze
    UPPERCASE_LETTERS = ('A'..'Z').to_a.freeze
    LOWERCASE_LETTERS = ('a'..'z').to_a.freeze
    ALPHANUMERIC_CHARACTERS = (DIGITS + UPPERCASE_LETTERS + LOWERCASE_LETTERS).freeze
    NON_ALPHANUMERIC_CHARACTERS = "\0 \t\r\n\u{9b}\u2028\u2029?:,[]{}%@`"
    PLUS_MINUS = '+-'
    ESCAPE_REPLACEMENTS = {
      '0' => "\0",
      'a' => "\x07",
      'b' => "\x08",
      't' => "\x09",
      "\t" => "\x09",
      'n' => "\x0A",
      'v' => "\x0B",
      'f' => "\x0C",
      'r' => "\x0D",
      'e' => "\x1B",
      ' ' => "\x20",
      '"' => '"',
      '/' => '/',  # as per http://www.json.org/
      '\\' => '\\',
      'N' => "\u{9b}",
      '_' => "\u{A0}",
      'L' => "\u2028",
      'P' => "\u2029"
    }.freeze
    ESCAPE_CODES = { 'x' => 2, 'u' => 4, 'U' => 8 }.freeze

    def initialize(loader = nil)
      # It is assumed that Scanner and Reader will have a common descendant.
      # Reader do the dirty work of checking for BOM and converting the
      # input data to Unicode. It also adds NUL to the end.
      #
      # Reader supports the following methods
      #   self.peek(i=0)    # peek the next i-th character
      #   self.prefix(l=1)  # peek the next l characters
      #   self.forward(l=1) # read the next l characters and move the pointer

      @loader = loader
      if @loader && !@loader.respond_to?(:_scanner)
        @loader._scanner = self
      end
      reset_scanner
      @first_time = false
      @yaml_version = nil
    end

    attr_reader :yaml_version, :possible_simple_keys

    def flow_level
      @flow_context.size
    end

    def reset_scanner
      # Had we reached the end of the stream?
      @done = false

      # flow_context is an expanding/shrinking list consisting of '{' and '['
      # for each unclosed flow context. If empty list that means block context
      @flow_context = []

      # List of processed tokens that are not yet emitted.
      @tokens = []

      # Add the STREAM-START token.
      fetch_stream_start

      # Number of tokens that were emitted through the `get_token` method.
      @tokens_taken = 0

      # The current indentation level.
      @indent = -1

      # Past indentation levels.
      @indents = []

      # Variables related to simple keys treatment.

      # A simple key is a key that is not denoted by the '?' indicator.
      # Example of simple keys:
      #   ---
      #   block simple key: value
      #   ? not a simple key:
      #   : { flow simple key: value }
      # We emit the KEY token before all keys, so when we find a potential
      # simple key, we try to locate the corresponding ':' indicator.
      # Simple keys should be limited to a single line and 1024 characters.

      # Can a simple key start at the current position? A simple key may
      # start:
      # - at the beginning of the line, not counting indentation spaces
      #       (in block context),
      # - after '{', '[', ',' (in the flow context),
      # - after '?', ':', '-' (in the block context).
      # In the block context, this flag also signifies if a block collection
      # may start at the current position.
      @allow_simple_key = true

      # Keep track of possible simple keys. This is a dictionary. The key
      # is `flow_level`; there can be no more that one possible simple key
      # for each level. The value is a SimpleKey record:
      #   (token_number, required, index, line, column, mark)
      # A simple key may start with ALIAS, ANCHOR, TAG, SCALAR(flow),
      # '[', or '{' tokens.
      @possible_simple_keys = {}
    end

    def reader
      return(@_scanner_reader) if defined?(@_scanner_reader)
      # rescue AttributeError
      if @loader.respond_to?(:typ)
        @_scanner_reader = @loader.reader
      else
        @_scanner_reader = @loader._reader
      end
    end

    def scanner_processing_version  # prefix until un-composited
      return(@scanner_processing_version) if defined?(@scanner_processing_version)

      @scanner_processing_version =
        if @loader.respond_to?(:typ)
          @loader.resolver.processing_version
        else
          @loader.processing_version
        end
    end

    # public

    def check_token(*choices)
      # Check if the next token is one of the given types.
      while need_more_tokens
        fetch_more_tokens
      end
      if @tokens.size > 0
        return true if choices.empty?
        first_token = @tokens[0]
        choices.each { |choice| return true if first_token.instance_of?(choice) }
      end
      false
    end

    def peek_token
      # Return the next token, but do not delete it from the queue.
      while need_more_tokens
        fetch_more_tokens
      end
      return(@tokens[0]) if @tokens.size > 0
    end

    def get_token
      # Return the next token.
      while need_more_tokens
        fetch_more_tokens
      end
      if @tokens.size > 0
        @tokens_taken += 1
        return @tokens.pop(0)
      end
    end

    # private

    def need_more_tokens
      return false if @done
      return true if @tokens.empty?
      # The current token may be a potential simple key, so we need to look further.
      stale_possible_simple_keys
      return true if next_possible_simple_key == @tokens_taken
      false
    end

    def fetch_comment(_comment)
      raise NotImplementedError
    end

    def fetch_more_tokens
      # Eat whitespaces and comments until we reach the next token.
      comment = scan_to_next_token
      return fetch_comment(comment) if comment # never happens for base scanner
      # Remove obsolete possible simple keys.
      stale_possible_simple_keys

      # Compare the current indentation and column. It may add some tokens
      # and decrease the current indentation level.
      unwind_indent(reader.column)

      # Peek the next character.
      ch = reader.peek

      # Is it the end of stream?
      return fetch_stream_end if ch == "\0"

      # Is it a directive?
      return fetch_directive if ch == '%' && check_directive

      # Is it the document start?
      return fetch_document_start if ch == '-' && check_document_start

      # Is it the document end?
      return fetch_document_end if ch == '.' && check_document_end

      # TODO: support for BOM within a stream.
      # return fetch_bom if ch == "\uFEFF" # <-- issue BOMToken

      # Note: the order of the following checks is NOT significant.

      # Is it the flow sequence start indicator?
      return fetch_flow_sequence_start if ch == '['

      # Is it the flow mapping start indicator?
      return fetch_flow_mapping_start if ch == '{'

      # Is it the flow sequence end indicator?
      return fetch_flow_sequence_end if ch == ']'

      # Is it the flow mapping end indicator?
      return fetch_flow_mapping_end if ch == '}'

      # Is it the flow entry indicator?
      return fetch_flow_entry if ch == ','

      # Is it the block entry indicator?
      return fetch_block_entry if ch == '-' && check_block_entry

      # Is it the key indicator?
      return fetch_key if ch == '?' && check_key

      # Is it the value indicator?
      return fetch_value if ch == '' && check_value

      # Is it an alias?
      return fetch_alias if ch == '*'

      # Is it an anchor?
      return fetch_anchor if ch == '&'

      # Is it a tag?
      return fetch_tag if ch == '!'

      # Is it a literal scalar?
      return fetch_literal if (ch == '|') && flow_level > 0

      # Is it a folded scalar?
      return fetch_folded if (ch == '>') && flow_level > 0

      # Is it a single-quoted scalar?
      return fetch_single if ch == "'"

      # Is it a double-quoted scalar?
      return fetch_double if ch == '"'

      # It must be a plain scalar then.
      return fetch_plain if check_plain

      # No? It's an error. Let's produce a nice error message.
      raise ScannerError.new(
        'while scanning for the next token',
        nil,
        "found character #{ch} that cannot start any token",
        reader.get_mark
      )
    end

    # Simple keys treatment.

    def next_possible_simple_key
      # Return the number of the nearest possible simple key. Actually we
      # don't need to loop through the whole dictionary. We may replace it
      # with the following code:
      #   return nil unless possible_simple_keys
      #   return possible_simple_keys[possible_simple_keys.keys.min].token_number
      min_token_number = nil
      possible_simple_keys.each do |level|
        key = possible_simple_keys[level]
        if min_token_number.nil? || (key.token_number < min_token_number)
          min_token_number = key&.token_number
        end
      end
      min_token_number
    end

    def stale_possible_simple_keys
      # Remove entries that are no longer possible simple keys. According to
      # the YAML specification, simple keys
      # - should be limited to a single line,
      # - should be no longer than 1024 characters.
      # Disabling this procedure will allow simple keys of any length and
      # height (may cause problems if indentation is broken though).
      @possible_simple_keys.keys do |level|
        key = @possible_simple_keys[level]
        if (key.line != reader.line) || (reader.index - key.index > 1024)
          if key.required
            raise ScannerError.new(
              'while scanning a simple key',
              key.mark,
              "could not find expected ':'",
              reader.get_mark
            )
          end
          @possible_simple_keys.delete(level)
        end
      end
    end

    def save_possible_simple_key
      # The next token may start a simple key. We check if it's possible
      # and save its position. This function is called for
      #   ALIAS, ANCHOR, TAG, SCALAR(flow), '[', and '{'.

      # Check if a simple key is required at the current position.
      required = (flow_level != 0) && (@indent == reader.column)

      # The next token might be a simple key. Let's save its number and position.
      if @allow_simple_key
        remove_possible_simple_key
        token_number = @tokens_taken + @tokens.size
        @possible_simple_keys[flow_level] = SimpleKey.new(token_number, required, reader.index, reader.line, reader.column, reader.get_mark)
      end
    end

    def remove_possible_simple_key
      # Remove the saved possible key position at the current flow level.
      if @possible_simple_keys.has_key?(flow_level)
        key = @possible_simple_keys[flow_level]

        if key.required
          raise ScannerError.new(
            'while scanning a simple key',
            key.mark,
            "could not find expected ':'",
            reader.get_mark
          )
        end

        @possible_simple_keys[flow_level] = nil
      end
    end

    # Indentation functions.

    def unwind_indent(column)
      # In flow context, tokens should respect indentation.
      # Actually the condition should be `self.indent >= column` according to
      # the spec. But this condition will prohibit intuitively correct
      # constructions such as
      # key : {
      # }
      # ####
      # if self.flow_level and self.indent > column:
      #     raise ScannerError(None, None,
      #             "invalid intendation or unclosed '[' or '{'",
      #             self.reader.get_mark())

      # In the flow context, indentation is ignored. We make the scanner less
      # restrictive than specification requires.
      return unless flow_level == 0

      # In block context, we may need to issue the BLOCK-END tokens.
      while @indent > column
        mark = reader.get_mark
        @indent = @indents.pop
        @tokens.append(BlockEndToken.new(mark, mark))
      end
    end

    def add_indent(column)
      # Check if we need to increase indentation.
      if @indent < column
        @indents.append(@indent)
        @indent = column
        return true
      end
      false
    end

    # Fetchers.

    def fetch_stream_start
      # We always add STREAM-START as the first token and STREAM-END as the
      # last token.
      # Read the token.
      mark = reader.get_mark
      # Add STREAM-START.
      @tokens.append(StreamStartToken.new(mark, mark, reader.encoding))
    end

    def fetch_stream_end
      # Set the current indentation to -1.
      unwind_indent(-1)
      # Reset simple keys.
      remove_possible_simple_key
      @allow_simple_key = false
      @possible_simple_keys = {}
      # Read the token.
      mark = reader.get_mark
      # Add STREAM-END.
      @tokens.append(StreamEndToken.new(mark, mark))
      # The stream is finished.
      @done = true
    end

    def fetch_directive
      # Set the current intendation to -1.
      unwind_indent(-1)

      # Reset simple keys.
      remove_possible_simple_key
      @allow_simple_key = false

      # Scan and add DIRECTIVE.
      @tokens.append(scan_directive)
    end

    def fetch_document_start
      fetch_document_indicator(DocumentStartToken)
    end

    def fetch_document_end
      fetch_document_indicator(DocumentEndToken)
    end

    def fetch_document_indicator(token_class)
      # Set the current intendation to -1.
      unwind_indent(-1)

      # Reset simple keys. Note that there could not be a block collection
      # after '---'.
      remove_possible_simple_key
      @allow_simple_key = false

      # Add DOCUMENT-START or DOCUMENT-END.
      start_mark = reader.get_mark
      reader.forward(3)
      end_mark = reader.get_mark
      @tokens.append(token_class.new(start_mark, end_mark))
    end

    def fetch_flow_sequence_start
      fetch_flow_collection_start(FlowSequenceStartToken, '[')
    end

    def fetch_flow_mapping_start
      fetch_flow_collection_start(FlowMappingStartToken, '{')
    end

    def fetch_flow_collection_start(token_class, to_push)
      # '[' and '{' may start a simple key.
      save_possible_simple_key
      # Increase the flow level.
      @flow_context.append(to_push)
      # Simple keys are allowed after '[' and '{'.
      @allow_simple_key = true
      # Add FLOW-SEQUENCE-START or FLOW-MAPPING-START.
      start_mark = reader.get_mark
      reader.forward
      end_mark = reader.get_mark
      @tokens.append(token_class.new(start_mark, end_mark))
    end

    def fetch_flow_sequence_end
      fetch_flow_collection_end(FlowSequenceEndToken)
    end

    def fetch_flow_mapping_end
      fetch_flow_collection_end(FlowMappingEndToken)
    end

    def fetch_flow_collection_end(token_class)
      # Reset possible simple key on the current level.
      remove_possible_simple_key
      # Decrease the flow level.
      begin
        popped = @flow_context.pop
      rescue IndexError
        # We must not be in a list or object.
        # Defer error handling to the parser.
      end
      # No simple keys after ']' or '}'.
      @allow_simple_key = false
      # Add FLOW-SEQUENCE-END or FLOW-MAPPING-END.
      start_mark = reader.get_mark
      reader.forward
      end_mark = reader.get_mark
      @tokens.append(token_class.new(start_mark, end_mark))
    end

    def fetch_flow_entry
      # Simple keys are allowed after ','.
      @allow_simple_key = true
      # Reset possible simple key on the current level.
      remove_possible_simple_key
      # Add FLOW-ENTRY.
      start_mark = reader.get_mark
      reader.forward
      end_mark = reader.get_mark
      @tokens.append(FlowEntryToken.new(start_mark, end_mark))
    end

    def fetch_block_entry
      # Block context needs additional checks.
      unless flow_level != 0
        # Are we allowed to start a new entry?
        raise ScannerError.new(nil, nil, 'sequence entries are not allowed here', reader.get_mark) unless @allow_simple_key
        # We may need to add BLOCK-SEQUENCE-START.
        if add_indent(reader.column)
          mark = reader.get_mark
          @tokens.append(BlockSequenceStartToken.new(mark, mark))
        end
        # It's an error for the block entry to occur in the flow context,
        # but we let the parser detect this.
      end
      # Simple keys are allowed after '-'.
      @allow_simple_key = true
      # Reset possible simple key on the current level.
      remove_possible_simple_key

      # Add BLOCK-ENTRY.
      start_mark = reader.get_mark
      reader.forward
      end_mark = self.reader.get_mark
      @tokens.append(BlockEntryToken.new(start_mark, end_mark))
    end

    def fetch_key
      # Block context needs additional checks.
      unless flow_level == 0
        # Are we allowed to start a key (not nessesary a simple)?
        raise ScannerError.new(nil, nil, 'mapping keys are not allowed here', reader.get_mark) unless @allow_simple_key

        # We may need to add BLOCK-MAPPING-START.
        if add_indent(reader.column)
          mark = reader.get_mark
          @tokens.append(BlockMappingStartToken.new(mark, mark))
        end
      end

      # Simple keys are allowed after '?' in the block context.
      @allow_simple_key = (flow_level == 0)

      # Reset possible simple key on the current level.
      remove_possible_simple_key

      # Add KEY.
      start_mark = reader.get_mark
      reader.forward
      end_mark = reader.get_mark
      @tokens.append(KeyToken.new(start_mark, end_mark))
    end

    def fetch_value
      flow_level_as_boolean = flow_level > 0

      # Do we determine a simple key?
      if @possible_simple_keys.has_key?(flow_level)
        # Add KEY.
        key = @possible_simple_keys.delete(flow_level)
        @tokens.insert(key.token_number - @tokens_taken, KeyToken.new(key.mark, key.mark))

        # If this key starts a new block mapping, we need to add
        # BLOCK-MAPPING-START.
        unless flow_level_as_boolean
          @tokens.insert(key.token_number - @tokens_taken, BlockMappingStartToken.new(key.mark, key.mark)) if add_indent(key.column)
        end
        # There cannot be two simple keys one after another.
        @allow_simple_key = false
      else
        # It must be a part of a complex key.

        # Block context needs additional checks.
        # (Do we really need them? They will be caught by the parser
        # anyway.)
        unless flow_level_as_boolean
          # We are allowed to start a complex value if and only if
          # we can start a simple key.
          unless @allow_simple_key
            raise ScannerError.new(
              nil,
              nil,
              'mapping values are not allowed here',
              reader.get_mark
            )
          end
        end

        # If this value starts a new block mapping, we need to add
        # BLOCK-MAPPING-START.  It will be detected as an error later by
        # the parser.
        unless flow_level_as_boolean
          if add_indent(reader.column)
            mark = reader.get_mark
            @tokens.append(BlockMappingStartToken.new(mark, mark))
          end
        end

        # Simple keys are allowed after ':' in the block context.
        @allow_simple_key = !flow_level_as_boolean

        # Reset possible simple key on the current level.
        remove_possible_simple_key
      end

      # Add VALUE.
      start_mark = reader.get_mark
      reader.forward
      end_mark = reader.get_mark
      @tokens.append(ValueToken.new(start_mark, end_mark))
    end

    def fetch_alias
      # ALIAS could be a simple key.
      save_possible_simple_key
      # No simple keys after ALIAS.
      @allow_simple_key = false
      # Scan and add ALIAS.
      @tokens.append(scan_anchor(AliasToken))
    end

    def fetch_anchor
      # ANCHOR could start a simple key.
      save_possible_simple_key
      # No simple keys after ANCHOR.
      @allow_simple_key = false
      # Scan and add ANCHOR.
      @tokens.append(scan_anchor(AnchorToken))
    end

    def fetch_tag
      # TAG could start a simple key.
      save_possible_simple_key
      # No simple keys after TAG.
      @allow_simple_key = false
      # Scan and add TAG.
      @tokens.append(scan_tag)
    end

    def fetch_literal
      fetch_block_scalar('|')
    end

    def fetch_folded
      fetch_block_scalar('>')
    end

    def fetch_block_scalar(style)
      # A simple key may follow a block scalar.
      @allow_simple_key = true
      # Reset possible simple key on the current level.
      remove_possible_simple_key
      # Scan and add SCALAR.
      @tokens.append(scan_block_scalar(style))
    end

    def fetch_single
      fetch_flow_scalar("'")
    end

    def fetch_double
      fetch_flow_scalar('"')
    end

    def fetch_flow_scalar(style)
      # A flow scalar could be a simple key.
      save_possible_simple_key
      # No simple keys after flow scalars.
      @allow_simple_key = false
      # Scan and add SCALAR.
      @tokens.append(scan_flow_scalar(style))
    end

    def fetch_plain
      # A plain scalar could be a simple key.
      save_possible_simple_key
      # No simple keys after plain scalars. But note that `scan_plain` will
      # change this flag if the scan is finished at the beginning of the
      # line.
      @allow_simple_key = false
      # Scan and add SCALAR. May change `allow_simple_key`.
      @tokens.append(scan_plain)
    end

    # Checkers

    def check_directive
      # DIRECTIVE:        ^ '%' ...
      # The '%' indicator is already checked.
      reader.column == 0
    end

    def check_document_start
      # DOCUMENT-START:   ^ '---' (' '|'\n')
      reader.column == 0 && reader.prefix(3) == '---' && THE_END_SPACE_TAB.include?(reader.peek(3))
    end

    def check_document_end
      # DOCUMENT-END:     ^ '...' (' '|'\n')
      reader.column == 0 && reader.prefix(3) == '...' && THE_END_SPACE_TAB.include?(reader.peek(3))
    end

    def check_block_entry
      # BLOCK-ENTRY:      '-' (' '|'\n')
      THE_END_SPACE_TAB.include?(reader.peek(1))
    end

    def check_key
      # KEY(flow context):    '?'
      return true if flow_level != 0

      # KEY(block context):   '?' (' '|'\n')
      THE_END_SPACE_TAB.include?(reader.peek(1))
    end

    def check_value
      # VALUE(flow context):  ':'
      if scanner_processing_version == [1, 1]
        return true if flow_level.to_boolean
      else
        @peek_is_in_THE_END_SPACE_TAB = THE_END_SPACE_TAB.include?(reader.peek(1))
        if flow_level.to_boolean
          if @flow_context[-1] == '['
            return false unless @peek_is_in_THE_END_SPACE_TAB
          elsif @tokens && @tokens[-1].instance_of?(ValueToken)
            # mapping flow context scanning a value token
            return false unless @peek_is_in_THE_END_SPACE_TAB
          end

          return true
          # VALUE(block context): ':' (' '|'\n')
        end
      end

      @peek_is_in_THE_END_SPACE_TAB
    end

    def check_plain
      # A plain scalar may start with any non-space character except
      #   '-', '?', ':', ',', '[', ']', '{', '}',
      #   '#', '&', '*', '!', '|', '>', '\'', '\"',
      #   '%', '@', '`'.
      #
      # It may also start with
      #   '-', '?', ':'
      # if it is followed by a non-space character.
      #
      # Note that we limit the last rule to the block context (except the
      # '-' character) because we want the flow context to be space
      # independent.
      ch = reader.peek
      if scanner_processing_version == VERSION_1_1
        return (!"\0 \t\r\n\u{9b}\u2028\u2029-?:,[]{}#&*!|>'\"%@`".include?(ch)) ||
          (!THE_END_SPACE_TAB.include?(reader.peek(1)) &&
            (ch == '-' || (!flow_level && '?:'.include?(ch)))
          )
      end
      # YAML 1.2
      return true unless "\0 \t\r\n\u{9b}\u2028\u2029-?:,[]{}#&*!|>'\"%@`".include?(ch)
      # ###################                           ^ ???
      ch1 = reader.peek(1)
      return true if ch == '-' && !THE_END_SPACE_TAB.include?(ch1)
      return true if ch == ':' && flow_level.to_boolean && !SPACE_TAB.include?(ch1)

      return !THE_END_SPACE_TAB.include?(reader.peek(1)) &&
        (ch == '-' || (!flow_level && '?:'.include?(ch)))
    end

    # Scanners.

    def scan_to_next_token
      # We ignore spaces, line breaks and comments.
      # If we find a line break in the block context, we set the flag
      # `allow_simple_key` on.
      # The byte order mark is stripped if it's the first character in the
      # stream. We do not yet support BOM inside the stream as the
      # specification requires. Any such mark will be considered as a part
      # of the document.
      #
      # TODO: We need to make tab handling rules more sane. A good rule is
      #   Tabs cannot precede tokens
      #   BLOCK-SEQUENCE-START, BLOCK-MAPPING-START, BLOCK-END,
      #   KEY(block), VALUE(block), BLOCK-ENTRY
      # So the checking code is
      #   if <TAB>
      #       @allow_simple_keys = false
      # We also need to add the check for `allow_simple_keys == true` to
      # `unwind_indent` before issuing BLOCK-END.
      # Scanners for block, flow, and plain scalars need to be modified.
      reader.forward if reader.index == 0 && reader.peek == "\uFEFF"
      found = false
      until found
        while reader.peek == ' '
          reader.forward
        end
        if reader.peek == '#'
          until THE_END.include?(reader.peek)
            reader.forward
          end
        end
        if scan_line_break.empty?
          found = true
        else
          @allow_simple_key = true unless flow_level > 0
        end
      end
      nil
    end

    def scan_directive
      # See the specification for details.
      start_mark = reader.get_mark
      reader.forward
      name = scan_directive_name(start_mark)
      value = nil
      case name
      when 'YAML'
        value = scan_yaml_directive_value(start_mark)
        end_mark = reader.get_mark
      when 'TAG'
        value = scan_tag_directive_value(start_mark)
        end_mark = reader.get_mark
      else
        end_mark = reader.get_mark
        until THE_END.include?(reader.peek)
          reader.forward
        end
      end
      scan_directive_ignored_line(start_mark)
      return DirectiveToken.new(name, value, start_mark, end_mark)
    end

    def scan_directive_name(start_mark)
      # See the specification for details.
      length = 0
      ch = reader.peek(length)
      while ALPHANUMERIC_CHARACTERS.include?(ch) || '-_:.'.include?(ch)
        length += 1
        ch = reader.peek(length)
      end
      unless length > 0
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected alphabetic or numeric character, but found #{ch}",
          reader.get_mark,
          )
      end
      value = reader.prefix(length)
      reader.forward(length)
      ch = reader.peek
      unless THE_END_SPACE_TAB.include?(ch)
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected alphabetic or numeric character, but found #{ch}",
          reader.get_mark,
          )
      end
      value
    end

    def scan_yaml_directive_value(start_mark)
      # See the specification for details.
      while reader.peek == ' '
        reader.forward
      end
      major = scan_yaml_directive_number(start_mark)
      unless reader.peek == '.'
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected a digit or '.', but found #{reader.peek}",
          reader.get_mark,
          )
      end
      reader.forward
      minor = scan_yaml_directive_number(start_mark)
      unless THE_END_SPACE_TAB.include?(reader.peek)
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected a digit or '.', but found #{reader.peek}",
          reader.get_mark,
          )
      end
      @yaml_version = Gem::Version.new("#{major}.#{minor}")
    end

    def scan_yaml_directive_number(start_mark)
      # See the specification for details.
      ch = reader.peek
      unless DIGITS.include?(ch)
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected a digit, but found #{ch}",
          reader.get_mark,
          )
      end
      length = 0
      while DIGITS.include?(reader.peek(length))
        length += 1
      end
      value = (reader.prefix(length)).to_i
      reader.forward(length)
      value
    end

    def scan_tag_directive_value(start_mark)
      # See the specification for details.
      while reader.peek == ' '
        reader.forward
      end
      handle = scan_tag_directive_handle(start_mark)
      while reader.peek == ' '
        reader.forward
      end
      prefix = scan_tag_directive_prefix(start_mark)
      [handle, prefix]
    end

    def scan_tag_directive_handle(start_mark)
      # See the specification for details.
      value = scan_tag_handle('directive', start_mark)
      ch = reader.peek
      unless ch == ' '
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected ' ', but found #{ch}",
          reader.get_mark
          )
      end
      value
    end

    def scan_tag_directive_prefix(start_mark)
      # See the specification for details.
      value = scan_tag_uri('directive', start_mark)
      ch = reader.peek
      unless THE_END_SPACE_TAB.include?(ch)
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected ' ', but found #{ch}",
          reader.get_mark
          )
      end
      value
    end

    def scan_directive_ignored_line(start_mark)
      # See the specification for details.
      while reader.peek == ' '
        reader.forward
      end
      if reader.peek == '#'
        until THE_END.include?(reader.peek)
          reader.forward
        end
      end
      ch = reader.peek
      unless THE_END.include?(ch)
        raise ScannerError.new(
          'while scanning a directive',
          start_mark,
          "expected a comment or a line break, but found #{ch}",
          reader.get_mark
          )
      end
      scan_line_break
    end

    def scan_anchor(token_class)
      # The specification does not restrict characters for anchors and
      # aliases. This may lead to problems, for instance, the document
      #   [ *alias, value ]
      # can be interpteted in two ways, as
      #   [ "value" ]
      # and
      #   [ *alias , "value" ]
      # Therefore we restrict aliases to numbers and ASCII letters.
      start_mark = reader.get_mark
      indicator = reader.peek
      if indicator == '*'
        name = 'alias'
      else
        name = 'anchor'
      end
      reader.forward
      length = 0
      ch = reader.peek(length)
      while SweetStreetYaml.check_anchorname_char(ch)
        length += 1
        ch = reader.peek(length)
      end
      unless length > 0
        raise ScannerError.new(
          "while scanning an #{name}",
          start_mark,
          "expected alphabetic or numeric character, but found #{ch}",
          reader.get_mark,
          )
      end
      value = reader.prefix(length)
      reader.forward(length)
      unless NON_ALPHANUMERIC_CHARACTERS.include?(ch)
        raise ScannerError.new(
          "while scanning an #{name}",
          start_mark,
          "expected alphabetic or numeric character, but found #{ch}",
          reader.get_mark,
          )
      end
      end_mark = reader.get_mark
      token_class.new(value, start_mark, end_mark)
    end

    def scan_tag
      # See the specification for details.
      start_mark = reader.get_mark
      ch = reader.peek(1)
      if ch == '<'
        handle = nil
        reader.forward(2)
        suffix = scan_tag_uri('tag', start_mark)
        unless reader.peek == '>'
          raise ScannerError.new(
            'while parsing a tag',
            start_mark,
            "expected '>', but found #{reader.peek}",
            reader.get_mark
          )
        end
        reader.forward
      elsif THE_END_SPACE_TAB.include?(ch)
        handle = nil
        suffix = '!'
        reader.forward
      else
        length = 1
        use_handle = false
        until THE_END_SPACE_TAB.include?(ch)
          if ch == '!'
            use_handle = true
            break
          end
          length += 1
          ch = reader.peek(length)
        end
        handle = '!'
        if use_handle
          handle = scan_tag_handle('tag', start_mark)
        else
          handle = '!'
          reader.forward
        end
        suffix = scan_tag_uri('tag', start_mark)
      end
      ch = reader.peek
      unless THE_END_SPACE_TAB.include?(ch)
        raise ScannerError.new(
          'while scanning a tag',
          start_mark,
          "expected ' ', but found #{ch}",
          reader.get_mark
        )
      end
      value = [handle, suffix]
      end_mark = reader.get_mark
      TagToken.new(value, start_mark, end_mark)
    end

    def scan_block_scalar(style, rt = false)
      # See the specification for details.
      folded = (style == '>')

      chunks = []
      start_mark = reader.get_mark

      # Scan the header.
      reader.forward
      chomping, increment = scan_block_scalar_indicators(start_mark)
      # block scalar comment e.g. : |+  # comment text
      block_scalar_comment = scan_block_scalar_ignored_line(start_mark)

      # Determine the indentation level and go to the first non-empty line.
      min_indent = @indent + 1
      if increment.nil?
        # no increment and top level, min_indent could be 0
        if (min_indent < 1) &&
          (!'|>'.include?(style) ||
            ((scanner_processing_version == VERSION_1_1) &&
              @loader.__send__('top_level_block_style_scalar_no_indent_error_1_1'))
          )
          min_indent = 1
        end
        breaks, max_indent, end_mark = scan_block_scalar_indentation
        indent = [min_indent, max_indent].max
      else
        if min_indent < 1
          min_indent = 1
        end
        indent = min_indent + increment - 1
        breaks, end_mark = scan_block_scalar_breaks(indent)
      end
      line_break = ''

      # Scan the inner part of the block scalar.
      while reader.column == indent && reader.peek != "\0"
        chunks.extend(breaks)
        leading_non_space = !SPACE_TAB.include?(reader.peek)
        length = 0
        until THE_END.include?(reader.peek(length))
          length += 1
        end
        chunks.append(reader.prefix(length))
        reader.forward(length)
        line_break = scan_line_break
        breaks, end_mark = scan_block_scalar_breaks(indent)
        if '|>'.include?(style) && min_indent == 0
          # at the beginning of a line, if in block style see if
          # end of document/start_new_document
          break if check_document_start || check_document_end
        end

        if reader.column == indent && reader.peek != "\0"
          # Unfortunately, folding rules are ambiguous.
          #
          # This is the folding according to the specification

          chunks.append("\a") if rt && folded && line_break == "\n"
          if folded && line_break == "\n" && leading_non_space && !SPACE_TAB.include?(reader.peek)
            if breaks.empty?
              chunks.append(' ')
            end
          else
            chunks.append(line_break)

            # This is Clark Evans's interpretation (also in the spec examples)
            #
            # if folded && line_break == "\n"
            #   if breaks.empty?
            #     if !" \t".include?(reader.peek)
            #         chunks.append(' ')
            #     else
            #         chunks.append(line_break)
            #     end
            #   end
            # else
            #   chunks.append(line_break)
            # end
          end
        else
          break
        end
      end

      # Process trailing line breaks. The 'chomping' setting determines
      # whether they are included in the value.
      trailing = []
      chunks.append(line_break) if NIL_OR_TRUE.include?(chomping)
      if chomping == true
        chunks += breaks
      elsif NIL_OR_FALSE.include?(chomping)
        trailing += breaks
      end

      # We are done.
      token = ScalarToken.new(chunks.join, false, start_mark, end_mark, style)
      unless @loader.nil?
        comment_handler = @loader.__send__('comment_handling')
        if comment_handler.nil?
          unless block_scalar_comment.nil?
            token.add_comment_pre([block_scalar_comment])
          end
        end
      end
      trailing_size = trailing.size
      if trailing_size > 0
        # Eat whitespaces and comments until we reach the next token.
        unless @loader.nil?
          comment_handler = @loader.__send__('comment_handling')
          unless comment_handler.nil?
            line = end_mark.line - trailing_size
            trailing.each { |x|
              raise unless x[-1] == "\n"
              @comments.add_blank_line(x, 0, line)
              line += 1
            }
          end
        end
        comment = scan_to_next_token
        while comment
          trailing.append(' ' * comment[1].column + comment[0])
          comment = scan_to_next_token
        end
        unless @loader.nil?
          comment_handler = @loader.__send__('comment_handling')
          if comment_handler.nil?
            # Keep track of the trailing whitespace and following comments
            # as a comment token, if isn't all included in the actual value.
            comment_end_mark = reader.get_mark
            comment = CommentToken.new(trailing.join, end_mark, comment_end_mark)
            token.add_comment_post(comment)
          end
        end
        token
      end
    end

    def scan_block_scalar_indicators(start_mark)
      # See the specification for details.
      chomping = nil
      increment = nil
      ch = reader.peek
      if PLUS_MINUS.include?(ch)
        chomping = (ch == '+')
        reader.forward
        ch = reader.peek
        _check_indentation(ch, start_mark)
      else
        _check_indentation(ch, start_mark)
        if DIGITS.include?(ch)
          ch = reader.peek
          if PLUS_MINUS.include?(ch)
            chomping = (ch == '+')
          end
          reader.forward
        end
      end
      ch = reader.peek
      unless THE_END_SPACE_TAB.include?(ch)
        raise ScannerError.new(
          'while scanning a block scalar',
          start_mark,
          "expected chomping or indentation indicators, but found #{ch}",
          reader.get_mark
        )
      end
      [chomping, increment]
    end

    def scan_block_scalar_ignored_line(start_mark)
      # See the specification for details.
      prefix = +''
      comment = nil
      while reader.peek == ' '
        prefix += reader.peek
        reader.forward
      end
      if reader.peek == '#'
        comment = prefix
        until THE_END.include?(reader.peek)
          comment += reader.peek
          reader.forward
        end
      end
      ch = reader.peek
      unless THE_END.include?(ch)
        raise ScannerError.new(
          'while scanning a block scalar',
          start_mark,
          "expected a comment or a line break, but found #{ch}",
          reader.get_mark
        )
      end
      scan_line_break
      comment
    end

    def scan_block_scalar_indentation
      # See the specification for details.
      chunks = []
      max_indent = 0
      end_mark = reader.get_mark
      while LINE_ENDING.include?(reader.peek)
        if reader.peek == ' '
          reader.forward
          if reader.column > max_indent
            max_indent = reader.column
          end
        else
          chunks.append(scan_line_break)
          end_mark = reader.get_mark
        end
      end
      [chunks, max_indent, end_mark]
    end

    def scan_block_scalar_breaks(indent)
      # See the specification for details.
      chunks = []
      end_mark = reader.get_mark
      while reader.column < indent && reader.peek == ' '
        reader.forward
      end
      while LINE_ENDING.include?(reader.peek)
        chunks.append(scan_line_break)
        end_mark = reader.get_mark
        while reader.column < indent && reader.peek == ' '
          reader.forward
        end
      end
      return chunks, end_mark
    end

    def scan_flow_scalar(style)
      # See the specification for details.
      # Note that we loose indentation rules for quoted scalars. Quoted
      # scalars don't need to adhere indentation because " and ' clearly
      # mark the beginning and the end of them. Therefore we are less
      # restrictive then the specification requires. We only need to check
      # that document separators are not included in scalars.
      double_quoted = (style == '"')

      chunks = []
      start_mark = reader.get_mark
      quote = reader.peek
      reader.forward
      chunks += scan_flow_scalar_non_spaces(double_quoted, start_mark)
      until reader.peek == quote
        chunks += scan_flow_scalar_spaces(double_quoted, start_mark)
        chunks += scan_flow_scalar_non_spaces(double_quoted, start_mark)
      end
      reader.forward
      end_mark = reader.get_mark
      ScalarToken.new(chunks.join, false, start_mark, end_mark, style)
    end

    def scan_flow_scalar_non_spaces(double_quoted, start_mark)
      # See the specification for details.
      chunks = []
      loop do
        length = 0
        until THE_END_SPACE_QUOTE_BACKSLASH.include?(reader.peek(length))
          length += 1
        end
        unless length == 0
          chunks.append(reader.prefix(length))
          reader.forward(length)
        end
        ch = reader.peek
        if !double_quoted && ch == "'" && reader.peek(1) == "'"
          chunks.append("'")
          reader.forward(2)
        elsif (double_quoted && ch == "'") || (!double_quoted && '"\\'.include?(ch))
          chunks.append(ch)
          reader.forward
        elsif double_quoted && ch == '\\'
          reader.forward
          ch = reader.peek
          if ESCAPE_REPLACEMENTS.has_key?(ch)
            chunks.append(ESCAPE_REPLACEMENTS[ch])
            reader.forward
          elsif ESCAPE_CODES.has_key?(ch)
            length = ESCAPE_CODES[ch]
            reader.forward
            0.upto(length - 1) do |i|
              unless '0123456789ABCDEFabcdef'.include?(reader.peek(k))
                raise ScannerError.new(
                  'while scanning a double-quoted scalar',
                  start_mark,
                  "expected escape sequence of #{length} hexdecimal numbers, but found #{reader.peek(k)}",
                  reader.get_mark,
                  )
              end
            end
            code = reader.prefix(length).to_i(16)
            chunks.append(code.chr)
            reader.forward(length)
          elsif LINE_ENDING.include?(ch)
            scan_line_break
            chunks += scan_flow_scalar_breaks(double_quoted, start_mark)
          else
            raise ScannerError.new(
              'while scanning a double-quoted scalar',
              start_mark,
              "found unknown escape character #{ch}",
              reader.get_mark
              )
          end
        else
          return chunks
        end
      end
    end

    def scan_flow_scalar_spaces(double_quoted, start_mark)
      # See the specification for details.
      chunks = []
      length = 0
      while SPACE_TAB.include?(reader.peek(length))
        length += 1
      end
      whitespaces = reader.prefix(length)
      reader.forward(length)
      ch = reader.peek
      case ch
      when "\0"
        raise ScannerError.new(
          'while scanning a quoted scalar',
          start_mark,
          'found unexpected end of stream',
          reader.get_mark,
          )
      when LINE_ENDINGS_REGEXP
        line_break = scan_line_break
        breaks = scan_flow_scalar_breaks(double_quoted, start_mark)
        if line_break != "\n"
          chunks.append(line_break)
        elsif breaks.empty?
          chunks.append(' ')
          chunks += breaks
        end
      else
        chunks.append(whitespaces)
      end

      chunks
    end

    def scan_flow_scalar_breaks(double, start_mark)
      # See the specification for details.
      chunks = []
      loop do
        # Instead of checking indentation, we check for document separators.
        prefix = reader.prefix(3)
        if (prefix == '---' || prefix == '...') && THE_END_SPACE_TAB.include?(reader.peek(3))
          raise ScannerError.new(
            'while scanning a quoted scalar',
            start_mark,
            'found unexpected document separator',
            reader.get_mark,
            )
        end
        while SPACE_TAB.include?(reader.peek)
          reader.forward
        end
        if LINE_ENDING.include?(reader.peek)
          chunks.append(scan_line_break)
        else
          return chunks
        end
      end
    end

    def scan_plain
      # See the specification for details.
      # We add an additional restriction for the flow context
      #   plain scalars in the flow context cannot contain ',', ': '  and '?'.
      # We also keep track of the `allow_simple_key` flag here.
      # Indentation rules are loosed for the flow context.
      chunks = []
      start_mark = reader.get_mark
      end_mark = start_mark
      indent = @indent + 1
      # We allow zero indentation for scalars, but then we need to check for
      # document separators at the beginning of the line.
      # if indent == 0
      #     indent = 1
      spaces = []
      loop do
        length = 0
        break if reader.peek == '#'
        loop do
          ch = reader.peek(length)
          next if ch == ':' && !THE_END_SPACE_TAB.include?(reader.peek(length + 1))
          next if ch == '?' && scanner_processing_version != VERSION_1_1

          if (
          THE_END_SPACE_TAB.include?(ch) ||
            (
            flow_level == 0 &&
              ch == ':' &&
              THE_END_SPACE_TAB.include?(reader.peek(length + 1))
            ) ||
            (flow_level > 0 && ',:?[]{}'.include?(ch))
          )
            break
          end
          length += 1
        end
        # It's not clear what we should do with ':' in the flow context.
        if (
        flow_level > 0 &&
          ch == ':' &&
          !THE_END_SPACE_TAB_COMMA_BRACKETS.include?(reader.peek(length + 1))
        )
          reader.forward(length)
          raise ScannerError.new(
            'while scanning a plain scalar',
            start_mark,
            "found unexpected ':'",
            reader.get_mark,
            'Please check http://pyyaml.org/wiki/YAMLColonInFlowContext for details.'
          )
        end
        break if length == 0
        @allow_simple_key = false
        chunks += spaces
        chunks.append(reader.prefix(length))
        reader.forward(length)
        end_mark = reader.get_mark
        spaces = scan_plain_spaces(indent, start_mark)
        if (
        spaces.empty? ||
          reader.peek == '#' ||
          (flow_level == 0 && reader.column < indent)
        )
          break
        end
      end

      token = ScalarToken.new(chunks.join, true, start_mark, end_mark)
      # getattr provides true so C type loader, which cannot handle comment,
      # will not make CommentToken
      unless @loader.nil?
        comment_handler = @loader.__send__('comment_handling')
        if comment_handler.nil?
          if spaces[0] == "\n"
            # Create a comment token to preserve the trailing line breaks.
            comment = CommentToken.new(spaces.join + "\n", start_mark, end_mark)
            token.add_comment_post(comment)
          end
        elsif comment_handler != false
          line = start_mark.line + 1
          spaces.each { |ch|
            if ch == "\n"
              @comments.add_blank_line("\n", 0, line)
              line += 1
            end
          }
        end
      end

      token
    end

    def scan_plain_spaces(indent, start_mark)
      # See the specification for details.
      # The specification is really confusing about tabs in plain scalars.
      # We just forbid them completely. Do not use tabs in YAML!
      chunks = []
      length = 0
      while reader.peek(length) == ' '
        length += 1
      end
      whitespaces = reader.prefix(length)
      reader.forward(length)
      ch = reader.peek
      if LINE_ENDING.include?(ch)
        line_break = scan_line_break
        @allow_simple_key = true
        prefix = reader.prefix(3)
        return if (prefix == '---' || prefix == '...') && THE_END_SPACE_TAB.include?(reader.peek(3))
        breaks = []
        while LINE_ENDING_SPACE.include?(reader.peek)
          if reader.peek == ' '
            reader.forward
          else
            breaks.append(scan_line_break)
            prefix = reader.prefix(3)
            return if (prefix == '---' || prefix == '...') && THE_END_SPACE_TAB.include?(reader.peek(3))
          end
        end
        if line_break != "\n"
          chunks.append(line_break)
        elsif breaks.empty?
          chunks.append(' ')
        end
        chunks += breaks
      elsif whitespaces
        chunks.append(whitespaces)
      end

      chunks
    end

    def scan_tag_handle(name, start_mark)
      # See the specification for details.
      # For some strange reasons, the specification does not allow '_' in
      # tag handles. I have allowed it anyway.
      if ch != '!'
        raise ScannerError.new(
          "while scanning an #{name}",
          start_mark,
          "expected '!', but found #{ch}",
          reader.get_mark
          )
      end
      length = 1
      ch = reader.peek(length)
      if ch != ' '
        while ALPHANUMERIC_CHARACTERS.include?(ch) || '-_'.include?(ch)
          length += 1
          ch = reader.peek(length)
        end
        if ch != '!'
          reader.forward(length)
          raise ScannerError.new(
            "while scanning an #{name}",
            start_mark,
            "expected '!', but found #{ch}",
            reader.get_mark
            )
        end
        length += 1
      end
      value = reader.prefix(length)
      reader.forward(length)

      value
    end

    def scan_tag_uri(name, start_mark)
      # See the specification for details.
      # Note: we do not check if URI is well-formed.
      chunks = []
      length = 0
      ch = reader.peek(length)
      while (
      ALPHANUMERIC_CHARACTERS.include?(ch) ||
        "-;/?:@&=+$,_.!~*'()[]%".include?(ch) ||
        (ch == '#' && (scanner_processing_version > VERSION_1_1))
      )
        if ch == '%'
          chunks.append(reader.prefix(length))
          reader.forward(length)
          length = 0
          chunks.append(scan_uri_escapes(name, start_mark))
        else
          length += 1
        end
        ch = reader.peek(length)
        if length != 0
          chunks.append(reader.prefix(length))
          reader.forward(length)
          length = 0
        end
        if chunks.empty?
          raise ScannerError.new(
            "while parsing an #{name}",
            start_mark,
            "expected URI, but found #{ch}",
            reader.get_mark
          )
        end
      end

      chunks.join
    end

    def scan_uri_escapes(name, start_mark)
      # See the specification for details.
      code_bytes = []
      mark = reader.get_mark
      while reader.peek == '%'
        reader.forward
        0.upto(1) { |k|
          unless ALPHANUMERIC_CHARACTERS.include?(reader.peek(k))
            raise ScannerError.new(
              "while scanning an #{name}",
              start_mark,
              "expected URI escape sequence of 2 hexdecimal numbers, but found #{reader.peek(k)}",
              reader.get_mark
            )
          end
        }
        code_bytes.append(reader.prefix(2).to_i(16))
        reader.forward(2)
      end
      begin
        value = code_bytes.join.encode!('UTF-8')
      rescue UnicodeDecodeError => exc
        raise ScannerError.new(
          "while scanning an #{name}", start_mark, str(exc), mark
        )
      end

      value
    end

    def scan_line_break
      # Transforms
      #   '\r\n'      :   '\n'
      #   '\r'        :   '\n'
      #   '\n'        :   '\n'
      #   '\u{9b}'      :   '\n'
      #   '\u2028'    :   '\u2028'
      #   '\u2029     :   '\u2029'
      #   default     :   ''
      ch = reader.peek
      if ASCII_LINE_ENDING.include?(ch)
        if reader.prefix(2) == "\r\n"
          reader.forward(2)
        else
          reader.forward
        end
        return "\n"
      elsif UNICODE_LINE_ENDING.include?(ch)
        reader.forward
        return ch
      end

      ''
    end

    private

    def _check_indentation(ch, start_mark)
      if DIGITS.include?(ch)
        if ch.to_i == 0
          raise ScannerError.new(
            'while scanning a block scalar',
            start_mark,
            'expected indentation indicator in the range 1-9, ' 'but found 0',
            reader.get_mark
          )
        end
        reader.forward
      end
    end
  end

  class RoundTripScanner < Scanner
    using NumericExtensions

    def check_token(*choices)
      # Check if the next token is one of the given types.
      while need_more_tokens
        fetch_more_tokens
      end
      _gather_comments
      if @tokens.size > 0
        return true if choices.empty?
        choices.each { |choice| return true if @tokens[0].instance_of?(choice) }
      end
      false
    end

    def peek_token
      # Return the next token, but do not delete if from the queue.
      while need_more_tokens
        fetch_more_tokens
      end
      _gather_comments
      return @tokens[0] if @tokens.size > 0
    end

    def _gather_comments
      # combine multiple comment lines and assign to next non-comment-token
      comments = []
      return comments if @tokens.empty?
      if @tokens[0].instance_of?(CommentToken)
        comment = @tokens.pop(0)
        @tokens_taken += 1
        comments.append(comment)
      end
      while need_more_tokens
        fetch_more_tokens
        return comments if @tokens.empty?
        if @tokens[0].instance_of?(CommentToken)
          @tokens_taken += 1
          comment = @tokens.pop(0)
          comments.append(comment)
        end
      end
      if comments.size >= 1
        @tokens[0].add_comment_pre(comments)
      end
      # pull in post comment on e.g. ':'
      if !@done && @tokens.size < 2
        fetch_more_tokens
      end
    end

    def get_token
      # Return the next token.
      while need_more_tokens
        fetch_more_tokens
      end
      _gather_comments
      if @tokens.size > 0
        # only add post comment to single line tokens
        # scalar, value token. FlowXEndToken, otherwise
        # hidden streamtokens could get them (leave them and they will be
        # pre comments for the next map/seq
        if (
        @tokens.size > 1 &&
          (
          @tokens[0].instance_of?(ScalarToken) ||
            @tokens[0].instance_of?(ValueToken) ||
            @tokens[0].instance_of?(FlowSequenceEndToken) ||
            @tokens[0].instance_of?(FlowMappingEndToken)
          ) &&
          @tokens[1].instance_of?(CommentToken) &&
          @tokens[0].end_mark.line == @tokens[1].start_mark.line
        )
          @tokens_taken += 1
          c = @tokens.delete_at(1)
          fetch_more_tokens
          while @tokens.size > 1 && @tokens[1].instance_of?(CommentToken)
            @tokens_taken += 1
            c1 = @tokens.delete_at(1)
            c.value = c.value + (' ' * c1.start_mark.column) + c1.value
            fetch_more_tokens
          end
          @tokens[0].add_comment_post(c)
        elsif (
        @tokens.size > 1 &&
          @tokens[0].instance_of?(ScalarToken) &&
          @tokens[1].instance_of?(CommentToken) &&
          @tokens[0].end_mark.line != @tokens[1].start_mark.line
        )
          @tokens_taken += 1
          c = @tokens.delete_at(1)
          c.value = (
          '\n' * (c.start_mark.line - @tokens[0].end_mark.line)
          + (' ' * c.start_mark.column)
          + c.value
          )
          @tokens[0].add_comment_post(c)
          fetch_more_tokens
          while len(@tokens) > 1 and isinstance(@tokens[1], CommentToken)
            @tokens_taken += 1
            c1 = @tokens.delete_at(1)
            c.value = c.value + (' ' * c1.start_mark.column) + c1.value
            fetch_more_tokens
          end
        end
        @tokens_taken += 1
        return @tokens.delete_at(0)
      end
      # return nil
    end

    def fetch_comment(comment)
      value = comment[0]
      start_mark = comment[1]
      end_mark = comment[2]
      while value&.slice(-1) == ' '
        # empty line within indented key context
        # no need to update end-mark, that is not used
        value.chop!
      end
      @tokens.append(CommentToken.new(value, start_mark, end_mark))
    end

    # scanner

    def scan_to_next_token
      # We ignore spaces, line breaks and comments.
      # If we find a line break in the block context, we set the flag
      # `allow_simple_key` on.
      # The byte order mark is stripped if it's the first character in the
      # stream. We do not yet support BOM inside the stream as the
      # specification requires. Any such mark will be considered as a part
      # of the document.
      #
      # TODO: We need to make tab handling rules more sane. A good rule is
      #   Tabs cannot precede tokens
      #   BLOCK-SEQUENCE-START, BLOCK-MAPPING-START, BLOCK-END,
      #   KEY(block), VALUE(block), BLOCK-ENTRY
      # So the checking code is
      #   if <TAB>
      #       @allow_simple_keys = false
      # We also need to add the check for `allow_simple_keys == true` to
      # `unwind_indent` before issuing BLOCK-END.
      # Scanners for block, flow, and plain scalars need to be modified.

      if reader.index == 0 && reader.peek == "\uFEFF"
        reader.forward
      end
      found = false
      until found
        while reader.peek == ' '
          reader.forward
        end
        ch = reader.peek
        if ch == '#'
          start_mark = reader.get_mark
          comment = ch
          reader.forward
          until THE_END.include?(ch)
            ch = reader.peek
            if ch == "\0"  # don't gobble the end-of-stream character
              # but add an explicit newline as "YAML processors should terminate
              # the stream with an explicit line break
              # https://yaml.org/spec/1.2/spec.html#id2780069
              comment += "\n"
              break
            end
            comment += ch
            reader.forward
          end
          # gather any blank lines following the comment too
          ch = scan_line_break
          while ch.size > 0
            comment += ch
            ch = scan_line_break
          end
          end_mark = reader.get_mark
          unless flow_level.to_boolean
            @allow_simple_key = true
          end
          return comment, start_mark, end_mark
        end
        if scan_line_break == ''
          found = true
        else
          start_mark = reader.get_mark
          unless flow_level.to_boolean
            @allow_simple_key = true
          end
          ch = reader.peek
          if ch == "\n"  # empty toplevel lines
            start_mark = reader.get_mark
            comment = +""
            until ch.empty?
              ch = scan_line_break(empty_line=true)
              comment += ch
            end
            if reader.peek == '#'
              # empty line followed by indented real comment
              comment = comment[0...comment.rindex("\n")] + "\n"
            end
            end_mark = reader.get_mark
            return comment, start_mark, end_mark
          end
        end
      end
      # return nil
    end

    def scan_line_break(empty_line = false)
      # Transforms
      #   '\r\n'      :   '\n'
      #   '\r'        :   '\n'
      #   '\n'        :   '\n'
      #   '\u{9b}'      :   '\n'
      #   '\u2028'    :   '\u2028'
      #   '\u2029     :   '\u2029'
      #   default     :   ''
      ch = reader.peek
      if ASCII_LINE_ENDING.include?(ch)
        if reader.prefix(2) == "\r\n"
          reader.forward(2)
        else
          reader.forward
        end
        return "\n"
      elsif UNICODE_LINE_ENDING.include?(ch)
        reader.forward
        return ch
      elsif empty_line && "\t ".include?(ch)
        reader.forward
        return ch
      end

      ''
    end

    def scan_block_scalar(style, rt = true)
      super
    end
  end

  # commenthandling 2021, differentiatiation not needed

  VALUECMNT = 0
  KEYCMNT = 0  # 1
  # TAGCMNT = 2
  # ANCHORCMNT = 3


  class CommentBase
    attr_accessor :line, :column, :value, :uline, :used, :fline, :ufun, :function

    def initialize(value, line, column)
      @value = value
      @line = line
      @column = column
      @used = ' '
      # info = inspect.getframeinfo(
      #   inspect.stack()[3][0] # list of named tuples FrameInfo(frame, filename, lineno, function, code_context, index) is returned
      # ) # Traceback(filename, lineno, function, code_context, index) is returned
      _info = caller(3)[0] # "prog:13:in `<main>'"
      @function = _info[_info.rindex('`')..._info.rindex("'")] # info.function
      index_of_first_colon = _info.index( ':' )
      index_of_second_colon = _info.index( ':', index_of_first_colon )
      @fline = _info[index_of_first_colon...index_of_second_colon] # info.lineno
      @ufun = nil
      @uline = nil
    end

    def set_used(v = '+')
      @used = v
      # info = inspect.getframeinfo(inspect.stack()[1][0])
      _info = caller(1)[0]
      @ufun = _info[_info.rindex('`')..._info.rindex("'")] # info.function
      @uline = _info[index_of_first_colon...index_of_second_colon] # info.lineno
    end

    def set_assigned
      @used = '|'
    end

    def to_s
      "#{@value}"
    end

    def inspect
      "#{@value}"
    end
  end


  class EOLComment < CommentBase
    @@name = 'EOLC'
  end


  class FullLineComment < CommentBase
    @@name = 'FULL'
  end


  class BlankLineComment < CommentBase
    @@name = 'BLNK'
  end


  class ScannedComments
    def initialize
      @comments = {}
      @unused = []
    end

    def add_eol_comment(comment, column, line)
      if comment.count("\n") == 1
        raise unless comment[-1] == "\n"
      else
        raise unless comment.include?("\n")
      end
      @comments[line] = retval = EOLComment.new(comment[0...-1], line, column)
      @unused.append(line)
      retval
    end

    def add_blank_line(comment, column, line)
      # info = inspect.getframeinfo(inspect.stack()[1][0])
      raise unless (comment.count("\n") == 1 && comment[-1] == "\n")
      raise if @comments.include?(line)
      @comments[line] = retval = BlankLineComment.new(comment[0...-1], line, column)
      @unused.append(line)
      retval
    end

    def add_full_line_comment(comment, column, line)
      assert comment.count('\n') == 1 and comment[-1] == '\n'
      @comments[line] = retval = FullLineComment.new(comment[0...-1], line, column)
      @unused.append(line)
      retval
    end

    def [](idx)
      @comments[idx]
    end

    def to_str
      "ParsedComments:\n  "
      +
      @comments.items.map { |lineno, x| "#{lineno} #{x.info}" }.join("\n  ")
      + "\n"
    end

    def last
      lineno, x = @comments.items.to_a[-1]
      "#{lineno} {x.info}\n"
    end

    def any_unprocessed
      # ToDo: might want to differentiate based on lineno
      @unused.size > 0
      # for lno, comment in reversed(@comments.items())
      #    if comment.used == ' '
      #        return true
      # return false
    end

    def unprocessed(use = false)
      while @unused.size > 0
        first = use ? @unused.pop(0) : @unused[0]
        # info = inspect.getframeinfo(inspect.stack()[1][0])
        # xprintf('using', first, @comments[first].value, info.function, info.lineno)
        yield first, @comments[first]
        if use
          @comments[first].set_used
        end
      end
    end

    def assign_pre(token)
      token_line = token.start_mark.line
      # info = inspect.getframeinfo(inspect.stack()[1][0])
      # xprintf('assign_pre', token_line, @unused, info.function, info.lineno)
      gobbled = false
      while !@unused.empty? && @unused[0] < token_line
        gobbled = true
        first = @unused.pop(0)
        # xprintf('assign_pre < ', first)
        @comments[first].set_used()
        token.add_comment_pre(first)
      end
      gobbled
    end

    def assign_eol(tokens)
      return unless comment_line = @unused&.first

      return unless @comments[comment_line].instance(EOLComment)

      idx = 1
      _token = tokens[-idx]
      while _token.start_mark.line > comment_line || _token.instance_of?( ValueToken)
        idx += 1
      end
      # xprintf('idx1', idx)
      return if
        tokens.size > idx &&
          tokens[-idx].instance_of?(ScalarToken) &&
          tokens[-(idx + 1)].instance_of?(ScalarToken)

      begin
        if tokens[-idx].instance(ScalarToken) && tokens[-(idx + 1)].instance_of?(KeyToken)
          begin
            eol_idx = @unused.pop(0)
            @comments[eol_idx].set_used
            # xprintf('>>>>>a', idx, eol_idx, KEYCMNT)
            tokens[-idx].add_comment_eol(eol_idx, KEYCMNT)
          rescue IndexError
            raise NotImplementedError
          end
          return
        end
      rescue IndexError
        # xprintf('IndexError1')
      end

      begin
        if tokens[-idx].instance_of?(ScalarToken) &&
          ((_token = tokens[-(idx + 1)]).instance_of?(ValueToken) || _token.instance_of?(BlockEntryToken))
          begin
            eol_idx = @unused.pop(0)
            @comments[eol_idx].set_used()
            tokens[-idx].add_comment_eol(eol_idx, VALUECMNT)
          rescue IndexError
            raise NotImplementedError
          end
          return
        end
      rescue IndexError
        # xprintf('IndexError2')
      end

      # for t in tokens
      #     xprintf('tt-', t)
      # xprintf('not implemented EOL', type(tokens[-idx]))
      # import sys

      exit(0)
    end

    def assign_post(token)
      token_line = token.start_mark.line
      # info = inspect.getframeinfo(inspect.stack()[1][0])
      # xprintf('assign_post', token_line, @unused, info.function, info.lineno)
      gobbled = false
      while !@unused.empty? && @unused[0] < token_line
        gobbled = true
        first = @unused.pop(0)
        # xprintf('assign_post < ', first)
        @comments[first].set_used()
        token.add_comment_post(first)
      end
      gobbled
    end

    def str_unprocessed
      (
      @comments.items.map { |ind, x| "  #{ind} #{x.info}\n" } if x.used == ' '
      ).join
    end
  end


  class RoundTripScannerSC < Scanner  # RoundTripScanner Split Comments
    using NumericExtensions

    def initialize(*arg, **kw)
      super(*arg, **kw)
      raise if @loader.nil?
      # comments isinitialised on .need_more_tokens and persist on
      # @loader.parsed_comments
      @comments = nil
    end

    def get_token
      # Return the next token.
      while need_more_tokens
        fetch_more_tokens
      end
      if @tokens.size > 0
        if (_token = @tokens[0]).instance_of?(BlockEndToken)
          @comments.assign_post(_token)
        else
          @comments.assign_pre(_token)
        end
        @tokens_taken += 1
        @tokens.pop(0)
      end
    end

    def need_more_tokens
      if @comments.nil?
        @loader.parsed_comments = @comments = ScannedComments.new
      end
      return false if @done

      return true if @tokens.empty?

      # The current token may be a potential simple key, so we
      # need to look further.
      stale_possible_simple_keys
      return true if next_possible_simple_key == @tokens_taken

      return true if @tokens.size < 2

      first_token = @tokens[0]
      return true if first_token.start_mark.line == @tokens[-1].start_mark.line

      # if true
      #     xprintf('-x--', len(@tokens))
      #     for t in @tokens
      #         xprintf(t)
      #     # xprintf(@comments.last())
      #     xprintf(@comments.str_unprocessed())  # type: ignore
      @comments.assign_pre(first_token)
      @comments.assign_eol(@tokens)
    end

    def scan_to_next_token
      if reader.index == 0 && reader.peek == "\uFEFF"
        reader.forward
      end
      start_mark = reader.get_mark
      # xprintf('current_mark', start_mark.line, start_mark.column)
      found = false
      until found
        while reader.peek == ' '
          reader.forward
        end
        ch = reader.peek
        if ch == '#'
          comment_start_mark = reader.get_mark
          comment = ch
          reader.forward  # skip the '#'
          until THE_END.include?(ch)
            ch = reader.peek
            if ch == "\0"  # don't gobble the end-of-stream character
              # but add an explicit newline as "YAML processors should terminate
              # the stream with an explicit line break
              # https://yaml.org/spec/1.2/spec.html#id2780069
              comment += "\n"
              break
            end
            comment += ch
            reader.forward
          end
          # we have a comment
          if start_mark.column == 0
            @comments.add_full_line_comment(comment, comment_start_mark.column, comment_start_mark.line)
          else
            @comments.add_eol_comment(comment, comment_start_mark.column, comment_start_mark.line)
            comment = ''
          end
          # gather any blank lines or full line comments following the comment as well
          scan_empty_or_full_line_comments
          @allow_simple_key = true unless flow_level.to_boolean
          return
        end
        if scan_line_break.to_boolean
          # start_mark = reader.get_mark
          @allow_simple_key = true unless flow_level.to_boolean
          scan_empty_or_full_line_comments
          return nil
        end
        ch = reader.peek
        if ch == "\n"  # empty toplevel lines
          start_mark = reader.get_mark
          comment = +""
          while ch
            ch = scan_line_break(true)
            comment += ch
          end
          if reader.peek == '#'
            # empty line followed by indented real comment
            comment = comment[0...comment.rindex("\n")] + "\n"
          end
          _ = reader.get_mark  # gobble end_mark
          return nil
        else
          found = true
        end
      end
      # return nil
    end

    def scan_empty_or_full_line_comments
      blmark = reader.get_mark
      assert blmark.column == 0
      blanks = +""
      comment = nil
      mark = nil
      ch = reader.peek
      loop do
        # nprint('ch', repr(ch), reader.get_mark.column)
        if "\r\n\u{9b}\u2028\u2029".include?(ch)
          if reader.prefix(2) == "\r\n"
            reader.forward(2)
          else
            reader.forward
          end
          if comment.nil?
            blanks += "\n"
            @comments.add_blank_line(blanks, blmark.column, blmark.line)
          else
            comment += "\n"
            @comments.add_full_line_comment(comment, mark.column, mark.line)
            comment = nil
          end
          blanks = +""
          blmark = reader.get_mark
          ch = reader.peek
          next
        end
        if comment.nil?
          if ch " \t".include?(ch)
            blanks += ch
          elsif ch == '#'
            mark = reader.get_mark
            comment = '#'
          else
            # xprintf('breaking on', repr(ch))
            break
          end
        else
          comment += ch
        end
        reader.forward
        ch = reader.peek
      end
    end

    def scan_block_scalar_ignored_line(start_mark)
      # See the specification for details.
      prefix = +""
      comment = nil
      while reader.peek == ' '
        prefix += reader.peek
        reader.forward
      end
      if reader.peek == '#'
        comment = +""
        mark = reader.get_mark
        until THE_END.include?(reader.peek)
          comment += reader.peek
          reader.forward
        end
        comment += "\n"
      end
      ch = reader.peek
      until THE_END.include?(reader.peek)
        raise ScannerError.new(
          'while scanning a block scalar',
          start_mark,
          "expected a comment or a line break, but found #{ch}",
          reader.get_mark
        )
      end
      @comments.add_eol_comment(comment, mark.column, mark.line) unless comment.nil?
      scan_line_break
      nil
    end
  end
end
