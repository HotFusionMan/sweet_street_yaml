# encoding: utf-8

# frozen_string_literal: true

# This module contains abstractions for the input stream. You don't have to
# looks further, there are no pretty code.
#
# We define two classes here.
#
#   Mark(source, line, column)
# It's just a record and its only use is producing nice error messages.
# Parser does not use it for any other purposes.
#
#   Reader(source, data)
# Reader determines the encoding of `data` and converts it to unicode.
# Reader provides the following methods and attributes
#   reader.peek(length=1) - return the next `length` characters
#   reader.forward(length=1) - move the current position to `length`
#      characters.
#   reader.index - the number of the current character.
#   reader.line, stream.column - the line and the column of the current
#      character.


require_relative './error'
require_relative './compat'
require_relative './util'

module SweetStreetYaml
  class ReaderError < YAMLError
    attr_reader :character

    def initialize(name, position, character, encoding, reason)
      @name = name
      @character = character
      @position = position
      @encoding = encoding
      @reason = reason
    end

    def to_str
      if @character.instance_of?(bytes)
        "'#{encoding}' codec can't decode byte x#{character.ord}: '#{reason}\n'  in '#{name}', position #{position}"
      else
        "unacceptable character x#{character}: #{reason}\n  in '#{name}', position #{position}"
      end
    end
  end


  class Reader
    # Reader
    # - determines the data encoding and converts it to a unicode string,
    # - checks if characters are in allowed range,
    # - adds '\0' to the end.

    # Reader accepts
    #  - a `bytes` object,
    #  - a `str` object,
    #  - a file-like object with its `read` method returning `str`,
    #  - a file-like object with its `read` method returning `unicode`.

    # Yeah, it's ugly and slow.

    NON_PRINTABLE = Regexp.new("[^\x09\x0A\x0D\x20-\x7E\u{9b}\u{A0}-\uD7FF\uE000-\uFFFD\U00010000-\U0010FFFF]")

    def initialize(stream, loader = nil)
      @loader = loader
      @loader._reader ||= self
      reset_reader
      @stream = stream
    end

    attr_reader :encoding, :index, :column, :line

    def reset_reader
      @name = nil
      @stream_pointer = 0
      @eof = true
      @buffer = +""
      @pointer = 0
      @raw_buffer = nil
      @raw_decode = nil
      @encoding = nil
      @index = 0
      @line = 0
      @column = 0
    end

    def stream
      begin
        return @_stream
      rescue AttributeError
        raise YAMLStreamError.new('input stream needs to specified')
      end
    end

    def stream=(val)
      return if val.nil?

      @_stream = nil
      if val.instance_of?(String)
        @name = '<unicode string>'
        check_printable(val)
        @buffer = val + "\0"
        # elsif isinstance(val, bytes)
        #     name = '<byte string>'
        #     raw_buffer = val
        #     determine_encoding()
      else
        raise YAMLStreamError.new('stream argument needs to have a read() method') unless val.respond_to?(:read)
        @_stream = val
        @name = @stream.name || '<file>'
        @eof = false
        @raw_buffer = nil
        determine_encoding
      end
    end

    def peek(index = 0)
      peek_output = @buffer[@pointer + index]
      return peek_output if peek_output

      update(index + 1)
      return @buffer[@pointer + index]
    end

    def prefix(length = 1)
      update(length) if @pointer + length >= @buffer.size
      @buffer[@pointer...(@pointer + length)]
    end

    def forward_1_1(length = 1)
      update(length + 1) if @pointer + length + 1 >= @buffer.size
      until length == 0
        ch = @buffer[@pointer]
        @pointer += 1
        @index += 1
        if "\n\u{9b}\u2028\u2029".include?(ch) || (ch == "\r" && @buffer[@pointer] != "\n")
          @line += 1
          @column = 0
        elsif ch != "\uFEFF"
          @column += 1
        end
        length -= 1
      end
    end

    def forward(length = 1)
      update(length + 1) if @pointer + length + 1 >= @buffer.size
      until length == 0
        ch = @buffer[@pointer]
        @pointer += 1
        @index += 1
        if ch == "\n" || (ch == "\r" && @buffer[@pointer] != "\n")
          @line += 1
          @column = 0
        elsif ch != "\uFEFF"
          @column += 1
        end
        length -= 1
      end
    end

    def get_mark
      if stream.nil?
        StringMark.new(@name, @index, @line, @column, @buffer, @pointer)
      else
        FileMark.new(@name, @index, @line, @column)
      end
    end

    # def determine_encoding
    #     while not eof and (raw_buffer is nil or len(raw_buffer) < 2)
    #         update_raw()
    #     if isinstance(raw_buffer, bytes)
    #         if raw_buffer.startswith("\xff\xfe")
    #             raw_decode = codecs.utf_16_le_decode
    #             encoding = 'utf-16-le'
    #         elsif raw_buffer.startswith("\xfe\xff")
    #             raw_decode = codecs.utf_16_be_decode
    #             encoding = 'utf-16-be'
    #         else
    #             raw_decode = codecs.utf_8_decode  # type: ignore
    #             encoding = 'utf-8'
    #     update(1)


    @@_printable_ascii = ("\x09\x0A\x0D" + (0x20..0x7F).map(&:chr).join)#.encode('ascii')

    def self._get_non_printable_ascii(data)
      ascii_bytes = data.encode('ascii')
      non_printables = ascii_bytes.tr(@@_printable_ascii, '')
      return nil if non_printables.empty?
      non_printable = non_printables[0...-1]
      return ascii_bytes.index(non_printable), non_printable.decode('ascii')
    end

    def self._get_non_printable_regex(data)
      match = NON_PRINTABLE.match(data)
      return nil unless match.to_boolean
      return match.begin, match[0]
    end

    def self._get_non_printable(data)
      begin
        _get_non_printable_ascii(data)
      rescue EncodingError
        _get_non_printable_regex(data)
      end
    end

    def check_printable(data)
      non_printable_match = self.class._get_non_printable(data)
      unless non_printable_match.nil?
        start, character = non_printable_match
        @position = index + @buffer.size - @pointer + start
        raise ReaderError.new(
          @name,
          @position,
          ord(character),
          'unicode',
          'special characters are not allowed',
          )
      end
    end

    def update(length)
      return if @raw_buffer.nil?

      @buffer = @buffer[@pointer..-1]
      @pointer = 0
      while @buffer.size < length
        update_raw unless @eof
        if @raw_decode
          begin
            data, converted = @raw_decode.call(@raw_buffer, 'strict', @eof)
          rescue UnicodeDecodeError => exc
            character = @raw_buffer[exc.start]
            if !@stream.nil?
              @position = @stream_pointer - @raw_buffer.size + exc.start
            elsif !@stream.nil?
              @position = @stream_pointer - @raw_buffer.size + exc.start
            else
              @position = exc.start
            end
            raise ReaderError.new(@name, @position, character, exc.encoding, exc.reason)
          end
        else
          data = @raw_buffer
          converted = data.size
        end
        check_printable(data)
        @buffer += data
        @raw_buffer = @raw_buffer[converted..-1]
        if @eof
          @buffer += "\0"
          @raw_buffer = nil
          break
        end
      end
    end

    def update_raw(size = nil)
      data = @stream.read(size || 4096)
      if @raw_buffer.nil?
        @raw_buffer = data
      else
        @raw_buffer += data
      end
      @stream_pointer += data.size
      @eof = data.empty?
    end
  end
end
