# encoding: utf-8

# frozen_string_literal: true

# import sys
# import os
# import warnings
# import glob
# from importlib import import_module


# import ruamel.yaml
# from ruamel.yaml.error import UnsafeLoaderWarning, YAMLError  # NOQA
#
# from ruamel.yaml.tokens import *  # NOQA
# from ruamel.yaml.events import *  # NOQA
# from ruamel.yaml.nodes import *  # NOQA
#
# from ruamel.yaml.loader import BaseLoader, SafeLoader, Loader, RoundTripLoader  # NOQA
# from ruamel.yaml.dumper import BaseDumper, SafeDumper, Dumper, RoundTripDumper  # NOQA
# from ruamel.yaml.compat import StringIO, BytesIO, with_metaclass, nprint, nprintf  # NOQA
# from ruamel.yaml.resolver import VersionedResolver, Resolver  # NOQA
# from ruamel.yaml.representer import (
#     BaseRepresenter,
#     SafeRepresenter,
#     Representer,
#     RoundTripRepresenter,
# )
# from ruamel.yaml.constructor import (
#     BaseConstructor,
#     SafeConstructor,
#     Constructor,
#     RoundTripConstructor,
# )
# from ruamel.yaml.loader import Loader as UnsafeLoader
# from ruamel.yaml.comments import CommentedMap, CommentedSeq, C_PRE

require_relative './error'
require_relative './tokens'
require_relative './events'
require_relative './nodes'
require_relative './loader'
require_relative './dumper'
require_relative './resolver'
require_relative './representer'
require_relative './constructor'
require_relative './scanner'



# YAML is an acronym, i.e. spoken: rhymes with "camel". And thus a
# subset of abbreviations, which should be all caps according to PEP8


module SweetStreetYaml
  UnsafeLoader = Loader

  class YAML
    # typ: 'rt'/nil -> RoundTripLoader/RoundTripDumper,  (default)
    #      'safe'    -> SafeLoader/SafeDumper,
    #      'unsafe'  -> normal/unsafe Loader/Dumper
    #      'base'    -> baseloader
    # pure: if true only use Ruby code
    # input/output: needed to work as context manager
    # plug_ins: a list of plug-in files
    def initialize(*, typ: nil, pure: true)#, output: nil, plug_ins: nil)  # input: nil,
      @typ =
        if typ.nil?
          ['rt']
        else
          typ.instance_of?(Array) ? typ : [typ]
        end
      @pure = pure

      # @_input = input
      # @_output = output
      # @_context_manager = nil

      @plug_ins = []
      # for pu in ([] if plug_ins .nil? else plug_ins) + official_plug_ins
      #     file_name = pu.replace(os.sep, '.')
      #     plug_ins.append(import_module(file_name))
      # end
      @Resolver = VersionedResolver
      @allow_unicode = true
      @Reader = nil
      @Representer = nil
      @Constructor = nil
      @Scanner = nil
      @Serializer = nil
      @default_flow_style = nil
      @comment_handling = nil
      @typ_found = 1
      @setup_rt = false
      if @typ.include?('rt')
        @setup_rt = true
      elsif typ.include?('safe')
        @Emitter = (@pure || CEmitter.nil?) ? Emitter : CEmitter
        @Representer = SafeRepresenter
        @Parser = (@pure || CParser.nil?) ? Parser : CParser
        @Composer = Composer
        @Constructor = SafeConstructor
      elsif typ.include?('base')
        @Emitter = Emitter
        @Representer = BaseRepresenter
        @Parser = (@pure || CParser.nil?) ? Parser : CParser
        @Composer = Composer
        @Constructor = BaseConstructor
      elsif typ.include?('unsafe')
        @Emitter = (@pure || CEmitter.nil?) ? Emitter : CEmitter
        @Representer = Representer
        @Parser = (@pure || CParser.nil?) ? Parser : CParser
        @Composer = Composer
        @Constructor = Constructor
      elsif typ.include?('rtsc')
        @default_flow_style = false
        # no optimized rt-dumper yet
        @Emitter = Emitter
        @Serializer = Serializer
        @Representer = RoundTripRepresenter
        @Scanner = RoundTripScannerSC
        # no optimized rt-parser yet
        @Parser = RoundTripParserSC
        @Composer = Composer
        @Constructor = RoundTripConstructor
        @comment_handling = C_PRE
      else
        @setup_rt = true
        @typ_found = 0
      end
      if @setup_rt
        @default_flow_style = false
        # no optimized rt-dumper yet
        @Emitter = Emitter
        @Serializer = Serializer
        @Representer = RoundTripRepresenter
        @Scanner = RoundTripScanner
        # no optimized rt-parser yet
        @Parser = RoundTripParser
        @Composer = Composer
        @Constructor = RoundTripConstructor
      end
      @setup_rt = nil
      @stream = nil
      @canonical = nil
      @old_indent = nil
      @width = nil
      @line_break = nil

      @map_indent = nil
      @sequence_indent = nil
      @sequence_dash_offset = 0
      @compact_seq_seq = nil
      @compact_seq_map = nil
      @sort_base_mapping_type_on_output = nil  # default: sort

      @top_level_colon_align = nil
      @prefix_colon = nil
      @version = nil
      @preserve_quotes = nil
      @allow_duplicate_keys = false  # duplicate keys in map, set
      @encoding = 'utf-8'
      @explicit_start = nil
      @explicit_end = nil
      @tags = nil
      @default_style = nil
      @top_level_block_style_scalar_no_indent_error_1_1 = false
      # directives end indicator with single scalar document
      @scalar_after_indicator = nil
      # [a, b: 1, c: {d: 2}]  vs. [a, {b: 1}, {c: {d: 2}}]
      @brace_single_entry_mapping_in_flow_sequence = false
      # for module in plug_ins
      #     if getattr(module, 'typ', nil) in typ
      #         typ_found += 1
      #         module.init_typ
      #         break
      #     end
      # end
      if @typ_found == 0
        raise NotImplementedError.new(
          "typ '#{typ}' not recognized (need to install plug-in?)"
        )
      end
    end

    attr_reader :version, :typ, :comment_handling
    attr_accessor :_reader, :_constructor, :_parser, :_scanner, :_resolver, :_composer

    def reader
      @_reader ||= @Reader.new(nil, self)
    end

    def scanner
      @_scanner ||= @Scanner.new(self)
    end

    def parser
      unless @_parser
        if @Parser != :CParser
          @_parser = @Parser.new(self)
        else
          if @_parser.nil?
            # wait for the stream
            return nil
          else
            @_parser = CParser.new(@_stream)
          end
        end
      end
      @_parser
    end

    def composer
      @_composer ||= Composer.new(self)
    end

    def constructor
      unless @_constructor
        cnst = @Constructor.new(:preserve_quotes => @preserve_quotes, :loader => self)
        # cnst.allow_duplicate_keys = @allow_duplicate_keys
        @_constructor = cnst
      end
      @_constructor
    end

    def resolver
      @_resolver ||= VersionedResolver.new(:version => version, :loader => self)
    end

    def emitter
      return @_emitter if @_emitter

      if @Emitter != CEmitter
        _emitter = Emitter.new(
          nil,
          canonical=canonical,
          indent=old_indent,
          width=width,
          allow_unicode=allow_unicode,
          line_break=line_break,
          prefix_colon=prefix_colon,
          brace_single_entry_mapping_in_flow_sequence=brace_single_entry_mapping_in_flow_sequence,  # NOQA
          dumper=self,
          )
        @_emitter = _emitter
        @_emitter.best_map_indent = @map_indent if @map_indent
        @_emitter.best_sequence_indent = @sequence_indent if @sequence_indent
        @_emitter.sequence_dash_offset = @sequence_dash_offset if @sequence_dash_offset
        @_emitter.compact_seq_seq = @compact_seq_seq if @compact_seq_seq
        @_emitter.compact_seq_map = @compact_seq_map if @compact_seq_map
      else
        if @_stream.nil?
          # wait for the stream
          return nil
        end
        return nil
      end
    end

    def serializer
      @_serializer ||=
        Serializer.new(
          :encoding => encoding,
          :explicit_start => explicit_start,
          :explicit_end => explicit_end,
          :version => version,
          :tags => tags,
          :dumper => self
        )
    end

    def representer
      return @_representer if @_representer

      @_representer =
        Representer.new(
          :default_style => @default_style,
          :default_flow_style => @default_flow_style,
          :dumper => self
        )
      @_representer.sort_base_mapping_type_on_output = @sort_base_mapping_type_on_output if @sort_base_mapping_type_on_output
      @_representer
    end

    def scan(stream)
      # Scan a YAML stream and produce scanning tokens.
      return scan(stream.open('rb')) if !stream.respond_to?('read') && stream.respond_to?('open')

      _, my_parser = get_constructor_parser(stream)
      begin
        while scanner.check_token
          yield scanner.get_token
        end
      ensure
        my_parser.dispose
        begin
          @_reader.reset_reader
        rescue AttributeError
        end
        begin
          @_scanner.reset_scanner
        rescue AttributeError
        end
      end
    end

    def parse(stream)
      # Parse a YAML stream && produce parsing events.
      return parse(stream.open('rb')) if !stream.respond_to?('read') && stream.respond_to?('open')

      _, my_parser = get_constructor_parser(stream)
      begin
        while my_parser.check_event
          yield my_parser.get_event
        end
      ensure
        my_parser.dispose
        begin
          @_reader.reset_reader
        rescue AttributeError
        end
        begin
          @_scanner.reset_scanner
        rescue AttributeError
        end
      end
    end

    def compose(stream)
      # Parse the first YAML document in a stream and produce the corresponding representation tree.
      return compose(stream.open('rb')) if !stream.respond_to?('read') && stream.respond_to?('open')

      my_constructor, my_parser = get_constructor_parser(stream)
      begin
        return my_constructor.composer.get_single_node
      ensure
        my_parser.dispose
        begin
          @_reader.reset_reader
        rescue AttributeError
        end
        begin
          @_scanner.reset_scanner
        rescue AttributeError
        end
      end
    end

    def compose_all(stream)
      # Parse all YAML documents in a stream produce corresponding representation trees.
      my_constructor, my_parser = get_constructor_parser(stream)
      begin
        while my_constructor.composer.check_node
          yield my_constructor.composer.get_node
        end
      ensure
        my_parser.dispose
        begin
          @_reader.reset_reader
        rescue AttributeError
        end
        begin
          @_scanner.reset_scanner
        rescue AttributeError
        end
      end
    end

    # separate output resolver?

    def load(stream)
      # at this point you either have the non-pure Parser (which has its own reader and
      # scanner) or you have the pure Parser.
      # If the pure Parser is set, then set the Reader && Scanner, if not already set.
      # If either the Scanner or Reader are set, you cannot use the non-pure Parser,
      #     so reset it to the pure parser and set the Reader resp. Scanner if necessary
      return load(stream.open('rb')) if !stream.respond_to?('read') && stream.respond_to?('open')

      my_constructor, my_parser = get_constructor_parser(stream)
      begin
        return my_constructor.get_single_data
      ensure
        my_parser.dispose
        begin
          @_reader.reset_reader
        rescue AttributeError
        end
        begin
          @_scanner.reset_scanner
        rescue AttributeError
        end
      end
    end

    def load_all(stream)
      if !stream.respond_to?('read') && stream.respond_to?('open')
        stream.open('r') do |fp|
          load_all(fp).each { |d| yield d }
        end
        return
      end

      my_constructor, my_parser = get_constructor_parser(stream)
      begin
        while my_constructor.check_data
          yield my_constructor.get_data
        end
      ensure
        my_parser.dispose
        begin
          @_reader.reset_reader
        rescue AttributeError
        end
        begin
          @_scanner.reset_scanner
        rescue AttributeError
        end
      end
    end

    def get_constructor_parser(stream)
      # the old cyaml needs special setup, and therefore the stream
      if @Parser != :CParser
        @Reader = Reader if @Reader.nil?
        @Scanner = Scanner if @Scanner.nil?
        reader.stream = stream
=begin
      else
        if Reader
          Scanner ||= Scanner
          Parser = Parser
          reader.stream = stream
        elsif Scanner
          Reader ||= Reader
          Parser = Parser
          reader.stream = stream
        else
          # combined C level reader>scanner>parser
          # does some calls to the resolver, e.g. BaseResolver.descend_resolver
          # if you just initialise the CParser, to much of resolver.py
          # is actually used
          rslvr = Resolver

          class XLoader(Parser, Constructor, rslvr)
          def initialize(selfx, stream, version=version, preserve_quotes=nil)
            # type: (StreamTextType, Optional[VersionType], Optional[bool]) -> nil  # NOQA
            CParser.__init__(selfx, stream)
            selfx._parser = selfx._composer = selfx
            Constructor.__init__(selfx, loader=selfx)
            selfx.allow_duplicate_keys = allow_duplicate_keys
            rslvr.__init__(selfx, version=version, loadumper=selfx)
          end
          end

          @_stream = stream
          my_loader = XLoader(stream)
          return my_loader, my_loader
        end
=end
      end
      return constructor, parser
    end

    def emit(events, stream)
      # Emit YAML parsing events into a stream.
      # If stream.nil?, return the produced string instead.
      _, _, my_emitter = get_serializer_representer_emitter(stream, nil)
      begin
        events.each { |event| my_emitter.emit(event) }
      ensure
        begin
          my_emitter.dispose
        rescue AttributeError
          raise
        end
      end
    end

    def serialize(node, stream)
      # Serialize a representation tree into a YAML stream.
      # If stream.nil?, return the produced string instead.
      serialize_all([node], stream)
    end

    def serialize_all(nodes, stream)
      # Serialize a sequence of representation trees into a YAML stream.
      # If stream.nil?, return the produced string instead.
      my_serializer, _, my_emitter = get_serializer_representer_emitter(stream, nil)
      begin
        my_serializer.open
        nodes.each { |node| my_serializer.serialize(node) }
        my_serializer.close
      ensure
        begin
          my_emitter.dispose
        rescue AttributeError
          raise
        end
      end
    end

    def dump(data, stream: nil, transform: nil)
      if @_context_manager
        raise TypeError.new('Missing output stream while dumping from context manager') unless @_output
        raise TypeError.new("#{self.class.name}#dump in the context manager cannot have transform keyword") if transform
        @_context_manager.dump(data)
      else  # old style
        raise TypeError.new('Need a stream argument when not dumping from context manager') unless stream
        return dump_all([data], stream, :transform => transform)
      end
    end

    def dump_all(documents, stream, transform: nil)
      raise NotImplementedError if @_context_manager
      @_output = stream
      @_context_manager = YAMLContextManager(self, transform=transform)
      documents.each { |data| @_context_manager.dump(data) }
      @_context_manager.teardown_output()
      @_output = nil
      @_context_manager = nil
    end

    # TODO: For completeness as a YAML library, implement this method:
    # def Xdump_all(documents, stream, transform: nil)
    #     # Serialize a sequence of Python objects into a YAML stream.
    #     if  !hasattr(stream, 'write') && hasattr(stream, 'open')
    #         # pathlib.Path() instance
    #         with stream.open('w') as fp
    #             return dump_all(documents, fp, transform=transform)
    #     # The stream should have the methods `write` && possibly `flush`.
    #     if top_level_colon_align is true
    #         tlca = max([len(str(x)) for x in documents[0]])  # type: Any
    #     else
    #         tlca = top_level_colon_align
    #     if transform !.nil?
    #         fstream = stream
    #         if encoding .nil?
    #             stream = StringIO()
    #         else
    #             stream = BytesIO()
    #     serializer, representer, emitter = get_serializer_representer_emitter(
    #         stream, tlca
    #     )
    #     try
    #         serializer.open()
    #         for data in documents
    #             try
    #                 representer.represent(data)
    #             rescue AttributeError
    #                 # nprint(dir(dumper._representer))
    #                 raise
    #         serializer.close()
    #     finally
    #         try
    #             emitter.dispose()
    #         rescue AttributeError
    #             raise
    #             # dumper.dispose()  # cyaml
    #         delattr(self, '_serializer')
    #         delattr(self, '_emitter')
    #     if transform
    #         val = stream.getvalue()
    #         if encoding
    #             val = val.decode(encoding)
    #         if fstream .nil?
    #             transform(val)
    #         else
    #             fstream.write(transform(val))
    #     return nil


        # C routines
    class XDumper#(representer, rslvr) # TODO: translate Python multiple inheritance to mixin modules
      def initialize(
        selfx,
        stream,
        default_style: nil,
        default_flow_style: nil,
        canonical: nil,
        indent: nil,
        width: nil,
        allow_unicode: nil,
        line_break: nil,
        encoding: nil,
        explicit_start: nil,
        explicit_end: nil,
        version: nil,
        tags: nil,
        block_seq_indent: nil,
        top_level_colon_align: nil,
        prefix_colon: nil
      )
        # CEmitter.__init__(
        #   selfx,
        #   stream,
        #   canonical=canonical,
        #   indent=indent,
        #   width=width,
        #   encoding=encoding,
        #   allow_unicode=allow_unicode,
        #   line_break=line_break,
        #   explicit_start=explicit_start,
        #   explicit_end=explicit_end,
        #   version=version,
        #   tags=tags,
        #   )
        selfx._emitter = selfx._serializer = selfx._representer = selfx
        @Representer = representer.new(default_style: default_style, default_flow_style: default_flow_style)
        @resolver = rslvr.new
      end
    end

    def get_serializer_representer_emitter(stream, tlca)
      # we have only .Serializer to deal with (vs .Reader & .Scanner), much simpler
      if @Emitter != CEmitter
        @Serializer ||= Serializer
        emitter.stream = stream
        emitter.top_level_colon_align = tlca
        emitter.scalar_after_indicator = @scalar_after_indicator if @scalar_after_indicator
        return serializer, representer, emitter
      end
      if @Serializer
        # cannot set serializer with CEmitter
        @Emitter = Emitter
        emitter.stream = stream
        emitter.top_level_colon_align = tlca
        emitter.scalar_after_indicator = @scalar_after_indicator if @scalar_after_indicator
        return serializer, representer, emitter
      end

      rslvr = @typ.include?('base') ? BaseResolver : Resolver

      @_stream = stream
      dumper = XDumper.new(
        stream,
        default_style: default_style,
        default_flow_style: default_flow_style,
        canonical: canonical,
        indent: old_indent,
        width: width,
        allow_unicode: allow_unicode,
        line_break: line_break,
        explicit_start: explicit_start,
        explicit_end: explicit_end,
        version: version,
        tags: tags
      )
      @_emitter = @_serializer = dumper
      return dumper, dumper, dumper
    end

    # basic types
    def map(**kw)
      if typ.include?('rt')
        CommentedMap.new(**kw)
      else
        Hash.new(**kw)
      end
    end

    def seq(args)
      if typ.include?('rt')
        CommentedSeq.new(*args)
      else
        return Array.new(*args)
      end
    end

    # helpers
    # def official_plug_ins
    #     # type: () -> Any
    #     "search for list of subdirs that are plug-ins, if __file__ is not available, e.g.
    #     single file installers that are not properly emulating a file-system (issue 324)
    #     no plug-ins will be found. If any are packaged, you know which file that are
    #     and you can explicitly provide it during instantiation
    #         yaml = ruamel.yaml.YAML(plug_ins=['ruamel/yaml/jinja2/__plug_in__'])
    #     "
    #     try
    #         bd = os.path.dirname(__file__)
    #     rescue NameError
    #         return []
    #     gpbd = os.path.dirname(os.path.dirname(bd))
    #     res = [x.replace(gpbd, "")[1:-3] for x in glob.glob(bd + '/*/__plug_in__.py')]
    #     return res

    # Mentioned only in _doc/dumpcls.ryd, which is about dumping Python objects:
    # def register_class(self, cls)
    #     # type:(Any) -> Any
    #     """
    #     register a class for dumping loading
    #     - if it has attribute yaml_tag use that to register, else use class name
    #     - if it has methods to_yaml/from_yaml use those to dump/load else dump attributes
    #       as mapping
    #     """
    #     tag = getattr(cls, 'yaml_tag', '!' + cls.__name__)
    #     try
    #         representer.add_representer(cls, cls.to_yaml)
    #     rescue AttributeError
    #
    #         def t_y(representer, data)
    #             # type: (Any, Any) -> Any
    #             return representer.represent_yaml_object(
    #                 tag, data, cls, flow_style=representer.default_flow_style
    #             )
    #
    #         representer.add_representer(cls, t_y)
    #     try
    #         constructor.add_constructor(tag, cls.from_yaml)
    #     rescue AttributeError
    #
    #         def f_y(constructor, node)
    #             # type: (Any, Any) -> Any
    #             return constructor.construct_yaml_object(node, cls)
    #
    #         constructor.add_constructor(tag, f_y)
    #     return cls

    # ### context manager

#     def __enter__
#         # type: () -> Any
#         _context_manager = YAMLContextManager
#         return self
#
#     def __exit__(self, typ, value, traceback)
#         # type: (Any, Any, Any) -> nil
#         if typ
#             nprint('typ', typ)
#         _context_manager.teardown_output()
#         # _context_manager.teardown_input()
#         _context_manager = nil
#
#     # ### backwards compatibility
#     def _indent(self, mapping=nil, sequence=nil, offset=nil)
#         # type: (Any, Any, Any) -> nil
#         if mapping !.nil?
#             map_indent = mapping
#         if sequence !.nil?
#             sequence_indent = sequence
#         if offset !.nil?
#             sequence_dash_offset = offset
#
#     @property
#     def indent
#         # type: () -> Any
#         return _indent
#
#     @indent.setter
#     def indent(self, val)
#         # type: (Any) -> nil
#         old_indent = val
#
#     @property
#     def block_seq_indent
#         # type: () -> Any
#         return sequence_dash_offset
#
#     @block_seq_indent.setter
#     def block_seq_indent(self, val)
#         # type: (Any) -> nil
#         sequence_dash_offset = val
#
#     def compact(self, seq_seq=nil, seq_map=nil)
#         # type: (Any, Any) -> nil
#         compact_seq_seq = seq_seq
#         compact_seq_map = seq_map
#
#
# class YAMLContextManager
#     def initialize(self, yaml, transform=nil)
#         # type: (Any, Any) -> nil  # used to be: (Any, Optional[Callable]) -> nil
#         _yaml = yaml
#         _output_inited = false
#         _output_path = nil
#         _output = _yaml._output
#         _transform = transform
#
#         # _input_inited = false
#         # _input = input
#         # _input_path = nil
#         # _transform = yaml.transform
#         # _fstream = nil
#
#         if  !hasattr(_output, 'write') && hasattr(_output, 'open')
#             # pathlib.Path() instance, open with the same mode
#             _output_path = _output
#             _output = _output_path.open('w')
#
#         # if  !hasattr(_stream, 'write') && hasattr(stream, 'open')
#         # if  !hasattr(_input, 'read') && hasattr(_input, 'open')
#         #    # pathlib.Path() instance, open with the same mode
#         #    _input_path = _input
#         #    _input = _input_path.open('r')
#
#         if _transform !.nil?
#             _fstream = _output
#             if _yaml.encoding .nil?
#                 _output = StringIO()
#             else
#                 _output = BytesIO()
#
#     def teardown_output
#         # type: () -> nil
#         if _output_inited
#             _yaml.serializer.close()
#         else
#             return
#         try
#             _yaml.emitter.dispose()
#         rescue AttributeError
#             raise
#             # dumper.dispose()  # cyaml
#         try
#             delattr(_yaml, '_serializer')
#             delattr(_yaml, '_emitter')
#         rescue AttributeError
#             raise
#         if _transform
#             val = _output.getvalue()
#             if _yaml.encoding
#                 val = val.decode(_yaml.encoding)
#             if _fstream .nil?
#                 _transform(val)
#             else
#                 _fstream.write(_transform(val))
#                 _fstream.flush()
#                 _output = _fstream  # maybe  !necessary
#         if _output_path !.nil?
#             _output.close()
#
#     def init_output(self, first_data)
#         # type: (Any) -> nil
#         if _yaml.top_level_colon_align is true
#             tlca = max([len(str(x)) for x in first_data])  # type: Any
#         else
#             tlca = _yaml.top_level_colon_align
#         _yaml.get_serializer_representer_emitter(_output, tlca)
#         _yaml.serializer.open()
#         _output_inited = true
#
#     def dump(self, data)
#         # type: (Any) -> nil
#         if  !_output_inited
#             init_output(data)
#         try
#             _yaml.representer.represent(data)
#         rescue AttributeError
#             # nprint(dir(dumper._representer))
#             raise
#
#     # def teardown_input
#     #     pass
#     #
#     # def init_input
#     #     # set the constructor && parser on YAML() instance
#     #     _yaml.get_constructor_parser(stream)
#     #
#     # def load
#     #     if  !_input_inited
#     #         init_input()
#     #     try
#     #         while _yaml.constructor.check_data()
#     #             yield _yaml.constructor.get_data()
#     #     finally
#     #         parser.dispose()
#     #         try
#     #             _reader.reset_reader()  # type: ignore
#     #         rescue AttributeError
#     #             pass
#     #         try
#     #             _scanner.reset_scanner()  # type: ignore
#     #         rescue AttributeError
#     #             pass
#
#
# def yaml_object(yml)
#     # type: (Any) -> Any
#     """ decorator for classes that needs to dump/load objects
#     The tag for such objects is taken from the class attribute yaml_tag (or the
#     class name in lowercase in case unavailable)
#     If methods to_yaml and/or from_yaml are available, these are called for dumping resp.
#     loading, default routines (dumping a mapping of the attributes) used otherwise.
#     """
#
#     def yo_deco(cls)
#         # type: (Any) -> Any
#         tag = getattr(cls, 'yaml_tag', '!' + cls.__name__)
#         try
#             yml.representer.add_representer(cls, cls.to_yaml)
#         rescue AttributeError
#
#             def t_y(representer, data)
#                 # type: (Any, Any) -> Any
#                 return representer.represent_yaml_object(
#                     tag, data, cls, flow_style=representer.default_flow_style
#                 )
#
#             yml.representer.add_representer(cls, t_y)
#         try
#             yml.constructor.add_constructor(tag, cls.from_yaml)
#         rescue AttributeError
#
#             def f_y(constructor, node)
#                 # type: (Any, Any) -> Any
#                 return constructor.construct_yaml_object(node, cls)
#
#             yml.constructor.add_constructor(tag, f_y)
#         return cls
#
#     return yo_deco
#

enc = nil


# Loader/Dumper are no longer composites, to get to the associated
# Resolver()/Representer(), etc., you need to instantiate the class


# def add_implicit_resolver(
#     tag, regexp, first=nil, Loader=nil, Dumper=nil, resolver=Resolver
# )
#     # type: (Any, Any, Any, Any, Any, Any) -> nil
#     """
#     Add an implicit scalar detector.
#     If an implicit scalar value matches the given regexp,
#     the corresponding tag is assigned to the scalar.
#     first is a sequence of possible initial characters || nil.
#     """
#     if Loader .nil? && Dumper .nil?
#         resolver.add_implicit_resolver(tag, regexp, first)
#         return
#     if Loader
#         if hasattr(Loader, 'add_implicit_resolver')
#             Loader.add_implicit_resolver(tag, regexp, first)
#         elsif issubclass(
#             Loader, (BaseLoader, SafeLoader, Loader, RoundTripLoader)
#         )
#             Resolver.add_implicit_resolver(tag, regexp, first)
#         else
#             raise NotImplementedError
#     if Dumper
#         if hasattr(Dumper, 'add_implicit_resolver')
#             Dumper.add_implicit_resolver(tag, regexp, first)
#         elsif issubclass(
#             Dumper, (BaseDumper, SafeDumper, Dumper, RoundTripDumper)
#         )
#             Resolver.add_implicit_resolver(tag, regexp, first)
#         else
#             raise NotImplementedError


# this code currently not tested
# def add_path_resolver(tag, path, kind=nil, Loader=nil, Dumper=nil, resolver=Resolver)
#     # type: (Any, Any, Any, Any, Any, Any) -> nil
#     """
#     Add a path based resolver for the given tag.
#     A path is a list of keys that forms a path
#     to a node in the representation tree.
#     Keys can be string values, integers, || nil.
#     """
#     if Loader .nil? && Dumper .nil?
#         resolver.add_path_resolver(tag, path, kind)
#         return
#     if Loader
#         if hasattr(Loader, 'add_path_resolver')
#             Loader.add_path_resolver(tag, path, kind)
#         elsif issubclass(
#             Loader, (BaseLoader, SafeLoader, Loader, RoundTripLoader)
#         )
#             Resolver.add_path_resolver(tag, path, kind)
#         else
#             raise NotImplementedError
#     if Dumper
#         if hasattr(Dumper, 'add_path_resolver')
#             Dumper.add_path_resolver(tag, path, kind)
#         elsif issubclass(
#             Dumper, (BaseDumper, SafeDumper, Dumper, RoundTripDumper)
#         )
#             Resolver.add_path_resolver(tag, path, kind)
#         else
#             raise NotImplementedError


# def add_constructor(tag, object_constructor, Loader=nil, constructor=Constructor)
#     # type: (Any, Any, Any, Any) -> nil
#     """
#     Add an object constructor for the given tag.
#     object_onstructor is a function that accepts a Loader instance
#     && a node object && produces the corresponding Python object.
#     """
#     if Loader .nil?
#         constructor.add_constructor(tag, object_constructor)
#     else
#         if hasattr(Loader, 'add_constructor')
#             Loader.add_constructor(tag, object_constructor)
#             return
#         if issubclass(Loader, BaseLoader)
#             BaseConstructor.add_constructor(tag, object_constructor)
#         elsif issubclass(Loader, SafeLoader)
#             SafeConstructor.add_constructor(tag, object_constructor)
#         elsif issubclass(Loader, Loader)
#             Constructor.add_constructor(tag, object_constructor)
#         elsif issubclass(Loader, RoundTripLoader)
#             RoundTripConstructor.add_constructor(tag, object_constructor)
#         else
#             raise NotImplementedError


# def add_multi_constructor(tag_prefix, multi_constructor, Loader=nil, constructor=Constructor)
#     # type: (Any, Any, Any, Any) -> nil
#     """
#     Add a multi-constructor for the given tag prefix.
#     Multi-constructor is called for a node if its tag starts with tag_prefix.
#     Multi-constructor accepts a Loader instance, a tag suffix,
#     && a node object && produces the corresponding Python object.
#     """
#     if Loader .nil?
#         constructor.add_multi_constructor(tag_prefix, multi_constructor)
#     else
#         if false && hasattr(Loader, 'add_multi_constructor')
#             Loader.add_multi_constructor(tag_prefix, constructor)
#             return
#         if issubclass(Loader, BaseLoader)
#             BaseConstructor.add_multi_constructor(tag_prefix, multi_constructor)
#         elsif issubclass(Loader, SafeLoader)
#             SafeConstructor.add_multi_constructor(tag_prefix, multi_constructor)
#         elsif issubclass(Loader, Loader)
#             Constructor.add_multi_constructor(tag_prefix, multi_constructor)
#         elsif issubclass(Loader, RoundTripLoader)
#             RoundTripConstructor.add_multi_constructor(tag_prefix, multi_constructor)
#         else
#             raise NotImplementedError


# def add_representer(data_type, object_representer, Dumper=nil, representer=Representer)
#     # type: (Any, Any, Any, Any) -> nil
#     """
#     Add a representer for the given type.
#     object_representer is a function accepting a Dumper instance
#     && an instance of the given data type
#     && producing the corresponding representation node.
#     """
#     if Dumper .nil?
#         representer.add_representer(data_type, object_representer)
#     else
#         if hasattr(Dumper, 'add_representer')
#             Dumper.add_representer(data_type, object_representer)
#             return
#         if issubclass(Dumper, BaseDumper)
#             BaseRepresenter.add_representer(data_type, object_representer)
#         elsif issubclass(Dumper, SafeDumper)
#             SafeRepresenter.add_representer(data_type, object_representer)
#         elsif issubclass(Dumper, Dumper)
#             Representer.add_representer(data_type, object_representer)
#         elsif issubclass(Dumper, RoundTripDumper)
#             RoundTripRepresenter.add_representer(data_type, object_representer)
#         else
#             raise NotImplementedError


# this code currently not tested
# def add_multi_representer(data_type, multi_representer, Dumper=nil, representer=Representer)
#     # type: (Any, Any, Any, Any) -> nil
#     """
#     Add a representer for the given type.
#     multi_representer is a function accepting a Dumper instance
#     && an instance of the given data type || subtype
#     && producing the corresponding representation node.
#     """
#     if Dumper .nil?
#         representer.add_multi_representer(data_type, multi_representer)
#     else
#         if hasattr(Dumper, 'add_multi_representer')
#             Dumper.add_multi_representer(data_type, multi_representer)
#             return
#         if issubclass(Dumper, BaseDumper)
#             BaseRepresenter.add_multi_representer(data_type, multi_representer)
#         elsif issubclass(Dumper, SafeDumper)
#             SafeRepresenter.add_multi_representer(data_type, multi_representer)
#         elsif issubclass(Dumper, Dumper)
#             Representer.add_multi_representer(data_type, multi_representer)
#         elsif issubclass(Dumper, RoundTripDumper)
#             RoundTripRepresenter.add_multi_representer(data_type, multi_representer)
#         else
#             raise NotImplementedError
  end

  # TODO:  Figure out whether the following two classes could be turned into Ruby that would serve the same purpose,
  # viz., allow a class to declare a class that inherits from YAMLObject, thereby allowing the class to be dumped
  # to YAML and loaded/parsed from YAML.
  # class YAMLObjectMetaclass#(type)
  #   "
  #     The metaclass for YAMLObject.
  #     "
  #
  #   def initialize(cls, name, bases, kwds)
  #     super(name, bases, kwds)
  #     if kwds.has_key?('yaml_tag') && kwds['yaml_tag']
  #       cls.yaml_constructor.add_constructor(cls.yaml_tag, cls.from_yaml)
  #       cls.yaml_representer.add_representer(cls, cls.to_yaml)
  #     end
  #   end
  # end
  #
  # class YAMLObject#(with_metaclass(YAMLObjectMetaclass))
  #   "
  #     An object that can dump itself to a YAML stream
  #     && load itself from a YAML stream.
  #     "
  #
  #   # attr_accessor ()  # no direct instantiation, so allow immutable subclasses
  #
  #   @yaml_constructor = SweetStreetYaml::Constructor
  #   @yaml_representer = SweetStreetYaml::Representer
  #
  #   @yaml_tag = nil
  #   @yaml_flow_style = nil
  #
  #   def self.from_yaml(cls, constructor, node)
  #     "
  #         Convert a representation node to a Python object.
  #         "
  #     return constructor.construct_yaml_object(node, cls)
  #   end
  #
  #   def self.to_yaml(cls, representer, data)
  #     "
  #         Convert a Python object to a representation node.
  #         "
  #     return representer.represent_yaml_object(
  #       cls.yaml_tag, data, cls, :flow_style => cls.yaml_flow_style
  #     )
  #   end
  # end
end
