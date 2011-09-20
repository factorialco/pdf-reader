# coding: utf-8

module PDF
  class Reader

    # high level representation of a single PDF page. Ties together the various
    # low level classes in PDF::Reader and provides access to the various
    # components of the page (text, images, fonts, etc) in convenient formats.
    #
    # If you require access to the raw PDF objects for this page, you can access
    # the Page dictionary via the page_object accessor. You will need to use the
    # objects accessor to help walk the page dictionary in any useful way.
    #
    class Page

      # lowlevel hash-like access to all objects in the underlying PDF
      attr_reader :objects

      # the raw PDF object that defines this page
      attr_reader :page_object

      # creates a new page wrapper.
      #
      # * objects - an ObjectHash instance that wraps a PDF file
      # * pagenum - an int specifying the page number to expose. 1 indexed.
      #
      def initialize(objects, pagenum)
        @objects, @pagenum = objects, pagenum
        @page_object = objects.deref(objects.page_references[pagenum - 1])

        unless @page_object.is_a?(::Hash)
          raise ArgumentError, "invalid page: #{pagenum}"
        end
      end

      # return the number of this page within the full document
      #
      def number
        @pagenum
      end

      # return a friendly string representation of this page
      #
      def inspect
        "<PDF::Reader::Page page: #{@pagenum}>"
      end

      # Returns the attributes that accompany this page. Includes
      # attributes inherited from parents.
      #
      def attributes
        {}.tap { |hash|
          page_with_ancestors.reverse.each do |obj|
            hash.merge!(@objects.deref(obj))
          end
        }
      end

      # Returns the resources that accompany this page. Includes
      # resources inherited from parents.
      #
      def resources
        @resources ||= @objects.deref(attributes[:Resources]) || {}
      end

      # Returns a Hash of color spaces that are available to this page
      #
      def color_spaces
        @objects.deref(resources[:ColorSpace]) || {}
      end

      # Returns a Hash of fonts that are available to this page
      #
      def fonts
        @objects.deref(resources[:Font]) || {}
      end

      # Returns a Hash of external graphic states that are available to this
      # page
      #
      def graphic_states
        @objects.deref(resources[:ExtGState]) || {}
      end

      # Returns a Hash of patterns that are available to this page
      #
      def patterns
        @objects.deref(resources[:Pattern]) || {}
      end

      # Returns an Array of procedure sets that are available to this page
      #
      def procedure_sets
        @objects.deref(resources[:ProcSet]) || []
      end

      # Returns a Hash of properties sets that are available to this page
      #
      def properties
        @objects.deref(resources[:Properties]) || {}
      end

      # Returns a Hash of shadings that are available to this page
      #
      def shadings
        @objects.deref(resources[:Shading]) || {}
      end

      # Returns a Hash of XObjects that are available to this page
      #
      def xobjects
        @objects.deref(resources[:XObject]) || {}
      end

      # returns the plain text content of this page encoded as UTF-8. Any
      # characters that can't be translated will be returned as a ▯
      #
      def text
        receiver = PageTextReceiver.new
        walk(receiver)
        receiver.content
      end
      alias :to_s :text

      # processes the raw content stream for this page in sequential order and
      # passes callbacks to the receiver objects.
      #
      # This is mostly low level and you can probably ignore it unless you need
      # access to something like the raw encoded text. For an example of how
      # this can be used as a basis for higher level functionality, see the
      # text() method
      #
      # If someone was motivated enough, this method is intended to provide all
      # the data required to faithfully render the entire page. If you find
      # some required data isn't available it's a bug - let me know.
      #
      # Many operators that generate callbacks will reference resources stored
      # in the page header - think images, fonts, etc. To facilitate these
      # operators, the first available callback is page=. If your receiver
      # accepts that callback it will be passed the current
      # PDF::Reader::Page object. Use the Page#resources method to grab any
      # required resources.
      #
      # It may help to think of each page as a self contained program made up of
      # a set of instructions and associated resources. Calling walk() executes
      # the program in the correct order and calls out to your implementation.
      #
      def walk(*receivers)
        callback(receivers, :page=, [self])
        content_stream(receivers, raw_content)
      end

      # returns the raw content stream for this page. This is plumbing, nothing to
      # see here unless you're a PDF nerd like me.
      #
      def raw_content
        contents = objects.deref(@page_object[:Contents])
        [contents].flatten.compact.map { |obj|
          objects.deref(obj)
        }.map { |obj|
          obj.unfiltered_data
        }.join
      end

      private

      def root
        root ||= objects.deref(@objects.trailer[:Root])
      end

      def content_stream(receivers, instructions)
        buffer       = Buffer.new(StringIO.new(instructions), :content_stream => true)
        parser       = Parser.new(buffer, @objects)
        params       = []

        while (token = parser.parse_token(PagesStrategy::OPERATORS))
          if token.kind_of?(Token) and PagesStrategy::OPERATORS.has_key?(token)
            callback(receivers, PagesStrategy::OPERATORS[token], params)
            params.clear
          else
            params << token
          end
        end
      rescue EOFError => e
        raise MalformedPDFError, "End Of File while processing a content stream"
      end

      # calls the name callback method on each receiver object with params as the arguments
      #
      def callback (receivers, name, params=[])
        receivers.each do |receiver|
          receiver.send(name, *params) if receiver.respond_to?(name)
        end
      end

      def page_with_ancestors
        [ @page_object ] + ancestors
      end

      def ancestors(origin = @page_object[:Parent])
        if origin.nil?
          []
        else
          obj = objects.deref(origin)
          [ select_inheritable(obj) ] + ancestors(obj[:Parent])
        end
      end

      # select the elements from a Pages dictionary that can be inherited by
      # child Page dictionaries.
      #
      def select_inheritable(obj)
        ::Hash[obj.select { |key, value|
          [:Resources, :MediaBox, :CropBox, :Rotate, :Parent].include?(key)
        }]
      end

    end
  end
end
