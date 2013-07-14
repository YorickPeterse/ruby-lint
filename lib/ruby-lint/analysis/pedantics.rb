module RubyLint
  module Analysis
    ##
    # The {RubyLint::Analysis::UselessRuby} class checks for various useless
    # Ruby features, the use of redundant tokens such as `then` for `if`
    # statements and various other pedantics.
    #
    class Pedantics < Base
      [:if, :unless, :until, :while].each do |type|
        define_method("on_#{type}") do |node|
          check_begin_token(node)
        end
      end

      [:on_preexe, :on_postexe].each do |method|
        define_method(method) do |node|
          warning('BEGIN/END is useless', node)
        end
      end

      private

      ##
      # Checks if a node's begin token matches "then" or "do" and if so adds a
      # warning for it.
      #
      # @param [RubyLint::AST::Node] node
      #
      def check_begin_token(node)
        return if node.location.is_a?(::Parser::Source::Map::Ternary)
        return unless node.location.begin
        if node.location.begin.is?('then') or node.location.begin.is?('do')
          info('the use of then/do is not needed here', node)
        end
      end
    end # Pedantics
  end # Analysis
end # RubyLint
