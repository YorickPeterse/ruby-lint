module RubyLint
  ##
  # {RubyLint::VirtualMachine} is the heart of ruby-lint. It takes a AST
  # generated by {RubyLint::Parser}, iterates it and builds various definitions
  # of methods, variables, etc.
  #
  # The virtual machine is a stack based virtual machine. Whenever certain
  # expressions are processed their values are stored in a stack which is then
  # later used for creating definitions (where applicable). For example, when
  # creating a new class a definition for the class is pushed on to a stack.
  # All code defined in this class is then stored in the definition at the end
  # of the stack.
  #
  # After a certain AST has been processed the VM will enter a read-only state
  # to prevent code from modifying it (either on purpose or by accident).
  #
  # ## Stacks
  #
  # The virtual machine uses two stacks:
  #
  # * `value_stack`
  # * `variable_stack`
  #
  # The value stack is used for storing raw values (e.g. integers) while the
  # variable stack is used for storing variable definitions (which in turn
  # store their values inside themselves).
  #
  # ## Definitions
  #
  # Built definitions are stored in {RubyLint::VirtualMachine#definitions} as a
  # single root definition called "root". This definition in turn contains
  # everything defined in a block of code that was processed by the VM.
  #
  # ## Associations
  #
  # The VM also keeps track of various nodes and their corresponding
  # definitions to make it easier to retrieve them later on. These are only
  # nodes/definitions related to a new scope such as a class or method
  # definition node.
  #
  # These associations are stored as a Hash in
  # {RubyLint::VirtualMachine#associations} with the keys set to the nodes and
  # the values to the corresponding definitions.
  #
  # ## Options
  #
  # The following extra options can be set in the constructor:
  #
  # * `:comments`: a Hash containing the comments for various AST nodes.
  # * `:extra_definitions`: a extra {RubyLint::Definition::RubyObject} object
  #   that will be added as the parent of the root definition.
  #
  # @!attribute [r] associations
  #  @return [Hash]
  #
  # @!attribute [r] comments
  #  @return [Hash]
  #
  # @!attribute [r] definitions
  #  @return [RubyLint::Definition::RubyObject]
  #
  # @!attribute [r] extra_definitions
  #  @return [RubyLint::Definition::RubyObject]
  #
  # @!attribute [r] value_stack
  #  @return [RubyLint::NestedStack]
  #
  # @!attribute [r] variable_stack
  #  @return [RubyLint::NestedStack]
  #
  # @!attribute [r] docstring_tags
  #  @return [RubyLint::Docstring::Mapping]
  #
  class VirtualMachine < Iterator
    include Helper::ConstantPaths

    attr_reader :associations,
      :comments,
      :definitions,
      :extra_definitions,
      :docstring_tags,
      :value_stack,
      :variable_stack

    private :value_stack, :variable_stack, :docstring_tags

    ##
    # Hash containing the definition types to copy when including/extending a
    # module.
    #
    # @return [Hash]
    #
    INCLUDE_CALLS = {
      'include' => {
        :const           => :const,
        :instance_method => :instance_method
      },
      'extend' => {
        :const           => :const,
        :instance_method => :method
      }
    }

    ##
    # Hash containing variable assignment types and the corresponding variable
    # reference types.
    #
    # @return [Hash]
    #
    ASSIGNMENT_TYPES = {
      :lvasgn => :lvar,
      :ivasgn => :ivar,
      :cvasgn => :cvar,
      :gvasgn => :gvar
    }

    ##
    # Collection of primitive value types.
    #
    # @return [Array]
    #
    PRIMITIVES = [:int, :float, :str, :sym]

    ##
    # Remaps the names for `on_send` callback nodes in cases where the original
    # name of a method could not be used. For example, `on_send_[]=` is
    # considered to be invalid syntax and thus its mapped to
    # `on_send_assign_member`.
    #
    # @return [Hash]
    #
    SEND_MAPPING = {'[]=' => 'assign_member'}

    ##
    # Array containing the various argument types of method definitions.
    #
    # @return [Array]
    #
    ARGUMENT_TYPES = [:arg, :optarg, :restarg, :blockarg, :kwoptarg]

    ##
    # The types of variables to export outside of a method definition.
    #
    # @return [Array]
    #
    EXPORT_VARIABLES = [:ivar, :cvar, :const]

    ##
    # Array containing the directories to use for looking up definition files.
    #
    # @return [Array]
    #
    LOAD_PATH = [File.expand_path('../definitions/core', __FILE__)]

    ##
    # The available method visibilities.
    #
    # @return [Array]
    #
    VISIBILITIES = [:public, :protected, :private].freeze

    ##
    # @return [RubyLint::Definition::RubyObject]
    #
    def self.global_scope
      return @global_scope ||= Definition::RubyObject.new(
        :name => 'global',
        :type => :global
      )
    end

    ##
    # Looks up the given constant in the global scope. If it does not exist
    # this method will try to load it from one of the existing definitions.
    #
    # @param [String] name
    # @return [RubyLint::Definition::RubyObject]
    #
    def self.global_constant(name)
      found = global_scope.lookup_constant_path(name)

      if !found and !constant_loader.loaded?(name)
        constant_loader.load_constant(name)

        found = global_scope.lookup_constant_path(name)
      end

      return found
    end

    ##
    # Creates a new proxy for a global constant.
    #
    # @param [String] name The name of the constant, can include an entire
    #  constant path in the form of `Foo::Bar`.
    # @return [RubyLint::Definition::ConstantProxy]
    #
    def self.constant_proxy(name)
      return Definition::ConstantProxy.new(global_scope, name)
    end

    ##
    # @return [RubyLint::ConstantLoader]
    #
    def self.constant_loader
      return @constant_loader ||= ConstantLoader.new
    end

    ##
    # Called after a new instance of the virtual machine has been created.
    #
    def after_initialize
      @associations   = {}
      @definitions    = initial_definitions
      @scopes         = [@definitions]
      @in_sclass      = false
      @value_stack    = NestedStack.new
      @variable_stack = NestedStack.new
      @ignored_nodes  = []
      @visibility     = :public
      @comments     ||= {}

      reset_docstring_tags
      reset_method_type
    end

    ##
    # Processes the given AST. Constants are autoloaded first.
    #
    # @see #iterate
    #
    def run(ast)
      self.class.constant_loader.iterate(ast)

      iterate(ast)

      freeze
    end

    ##
    # Freezes the VM along with all the instance variables.
    #
    def freeze
      @associations.freeze
      @definitions.freeze
      @scopes.freeze

      super
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_root(node)
      associate_node(node, current_scope)
    end

    ##
    # Processes a regular variable assignment.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_assign(node)
      reset_assignment_value
      value_stack.add_stack
    end

    ##
    # @see #on_assign
    #
    def after_assign(node)
      type  = ASSIGNMENT_TYPES[node.type]
      name  = node.children[0].to_s
      value = value_stack.pop.first

      if !value and assignment_value
        value = assignment_value
      end

      assign_variable(type, name, value)
    end

    ASSIGNMENT_TYPES.each do |callback, type|
      alias_method :"on_#{callback}", :on_assign
      alias_method :"after_#{callback}", :after_assign
    end

    ##
    # Processes the assignment of a constant.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_casgn(node)
      # Don't push values for the receiver constant.
      @ignored_nodes << node.children[0] if node.children[0]

      reset_assignment_value
      value_stack.add_stack
    end

    ##
    # @see #on_casgn
    #
    def after_casgn(node)
      values = value_stack.pop
      scope  = current_scope

      if node.children[0]
        scope = resolve_constant_path(node.children[0])

        return unless scope
      end

      variable = Definition::RubyObject.new(
        :type          => :const,
        :name          => node.children[1].to_s,
        :value         => values.first,
        :instance_type => :instance
      )

      add_variable(variable, scope)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_masgn(node)
      add_stacks
    end

    ##
    # Processes a mass variable assignment using the stacks created by
    # {#on_masgn}.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_masgn(node)
      variables = variable_stack.pop
      values    = value_stack.pop.first
      values    = values ? values.value : []

      variables.each_with_index do |variable, index|
        variable.value = values[index].value if values[index]

        current_scope.add(variable.type, variable.name, variable)
      end
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_or_asgn(node)
      add_stacks
    end

    ##
    # Processes an `or` assignment in the form of `variable ||= value`.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_or_asgn(node)
      variable = variable_stack.pop.first
      value    = value_stack.pop.first

      if variable and value
        conditional_assignment(variable, value, false)
      end
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_and_asgn(node)
      add_stacks
    end

    ##
    # Processes an `and` assignment in the form of `variable &&= value`.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_and_asgn(node)
      variable = variable_stack.pop.first
      value    = value_stack.pop.first

      conditional_assignment(variable, value)
    end

    # Creates the callback methods for various primitives such as integers.
    PRIMITIVES.each do |type|
      define_method("on_#{type}") do |node|
        push_value(create_primitive(node))
      end
    end

    # Creates the callback methods for various variable types such as local
    # variables.
    ASSIGNMENT_TYPES.each do |asgn_name, type|
      define_method("on_#{type}") do |node|
        increment_reference_amount(node)
        push_variable_value(node)
      end
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_const(node)
      increment_reference_amount(node)
      push_variable_value(node)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_array(node)
      value_stack.add_stack
    end

    ##
    # Builds an Array.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_array(node)
      builder = DefinitionBuilder::RubyArray.new(
        node,
        current_scope,
        :values => value_stack.pop
      )

      push_value(builder.build)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_hash(node)
      value_stack.add_stack
    end

    ##
    # Builds a Hash.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_hash(node)
      builder = DefinitionBuilder::RubyHash.new(
        node,
        current_scope,
        :values => value_stack.pop
      )

      push_value(builder.build)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_pair(node)
      value_stack.add_stack
    end

    ##
    # Processes a key/value pair.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_pair(node)
      key, value = value_stack.pop

      return unless key

      member = Definition::RubyObject.new(
        :name  => key.value.to_s,
        :type  => :member,
        :value => value
      )

      push_value(member)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_self(node)
      push_value(current_scope.lookup(:keyword, 'self'))
    end

    ##
    # Creates the definition for a module.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_module(node)
      define_module(node, DefinitionBuilder::RubyModule)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def after_module(node)
      pop_scope
    end

    ##
    # Creates the definition for a class.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_class(node)
      parent      = nil
      parent_node = node.children[1]

      if parent_node
        parent = evaluate_node(parent_node)

        if !parent or !parent.const?
          parent = current_scope.lookup(:const, 'Object')
        end
      end

      define_module(node, DefinitionBuilder::RubyClass, :parent => parent)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def after_class(node)
      pop_scope
    end

    ##
    # Builds the definition for a block.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_block(node)
      builder    = DefinitionBuilder::RubyBlock.new(node, current_scope)
      definition = builder.build

      associate_node(node, definition)

      push_scope(definition)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def after_block(node)
      pop_scope
    end

    ##
    # Processes an sclass block. Sclass blocks look like the following:
    #
    #     class << self
    #
    #     end
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_sclass(node)
      parent       = node.children[0]
      definition   = evaluate_node(parent)
      @method_type = parent.self? ? :method : definition.method_call_type

      associate_node(node, definition)

      push_scope(definition)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def after_sclass(node)
      reset_method_type
      pop_scope
    end

    ##
    # Creates the definition for a method definition.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_def(node)
      receiver = nil

      if node.type == :defs
        receiver = evaluate_node(node.children[0])
      end

      builder = DefinitionBuilder::RubyMethod.new(
        node,
        current_scope,
        :type       => @method_type,
        :receiver   => receiver,
        :visibility => @visibility
      )

      definition = builder.build

      builder.scope.add_definition(definition)

      associate_node(node, definition)

      buffer_docstring_tags(node)

      if docstring_tags and docstring_tags.return_tag
        assign_return_value_from_tag(
          docstring_tags.return_tag,
          definition
        )
      end

      push_scope(definition)
    end

    ##
    # Exports various variables to the outer scope of the method definition.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_def(node)
      previous = pop_scope
      current  = current_scope

      reset_docstring_tags

      EXPORT_VARIABLES.each do |type|
        current.copy(previous, type)
      end
    end

    # Creates callbacks for various argument types such as :arg and :optarg.
    ARGUMENT_TYPES.each do |type|
      define_method("on_#{type}") do |node|
        value_stack.add_stack
      end

      define_method("after_#{type}") do |node|
        value = value_stack.pop.first
        name  = node.children[0].to_s
        var   = Definition::RubyObject.new(
          :type          => :lvar,
          :name          => name,
          :value         => value,
          :instance_type => :instance
        )

        if docstring_tags and docstring_tags.param_tags[name]
          update_parents_from_tag(docstring_tags.param_tags[name], var)
        end

        current_scope.add(type, name, var)
        current_scope.add_definition(var)
      end
    end

    alias_method :on_defs, :on_def
    alias_method :after_defs, :after_def

    ##
    # Processes a method call. If a certain method call has its own dedicated
    # callback that one will be called as well.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_send(node)
      name     = node.children[1].to_s
      name     = SEND_MAPPING.fetch(name, name)
      callback = "on_send_#{name}"

      value_stack.add_stack

      execute_callback(callback, node)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def after_send(node)
      receiver, name, _ = *node

      name        = name.to_s
      mapped_name = SEND_MAPPING.fetch(name, name)
      callback    = "after_send_#{mapped_name}"

      execute_callback(callback, node)

      args_length = node.children[2..-1].length
      values      = value_stack.pop

      # For now we'll get rid of the arguments since ruby-lint isn't smart
      # enough yet to process them.
      values.pop(args_length)

      receiver_definition = values.first

      # If the receiver doesn't exist there's no point in associating a context
      # with it.
      if receiver and !receiver_definition
        return
      end

      if receiver and receiver_definition
        context = receiver_definition
      else
        context = current_scope

        # `parser` wraps (block) nodes around (send) calls which is a bit
        # inconvenient
        context = previous_scope if context.block?
      end

      # Associate the receiver node with the context so that it becomes
      # easier to retrieve later on.
      if receiver and context
        associate_node(receiver, context)
      end

      if context and context.method_defined?(name)
        retval = context.call_method(name)

        push_value(retval)
      end
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_send_include(node)
      value_stack.add_stack
    end

    ##
    # Processes a `include` method call.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_send_include(node)
      copy_types = INCLUDE_CALLS[node.children[1].to_s]
      scope      = current_scope
      arguments  = value_stack.pop

      arguments.each do |source|
        copy_types.each do |from, to|
          source.list(from).each do |definition|
            scope.add(to, definition.name, definition)
          end
        end
      end
    end

    alias_method :on_send_extend, :on_send_include
    alias_method :after_send_extend, :after_send_include

    VISIBILITIES.each do |vis|
      define_method("on_send_#{vis}") do |node|
        @visibility = vis
      end
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_send_assign_member(node)
      value_stack.add_stack
    end

    ##
    # Processes the assignment of an object member (array index or hash key).
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_send_assign_member(node)
      array, *indexes, values = value_stack.pop
      index_values            = []

      if values and values.array?
        index_values = values.list(:member).map(&:value)
      elsif values
        index_values = [values]
      end

      indexes.each do |index|
        member = Definition::RubyObject.new(
          :name  => index.value.to_s,
          :type  => :member,
          :value => index_values.shift
        )

        array.add_definition(member)
      end
    end

    ##
    # Processes `alias_method` method calls.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_send_alias_method(node)
      alias_node  = node.children[2]
      source_node = node.children[3]

      on_alias_sym(alias_node, source_node)
    end

    ##
    # Processes calls to `alias`. Two types of data can be aliased:
    #
    # 1. Methods (using the syntax `alias ALIAS SOURCE`)
    # 2. Global variables
    #
    # This method dispatches the alias process to two possible methods:
    #
    # * on_alias_sym: aliasing methods (using symbols)
    # * on_alias_gvar: aliasing global variables
    #
    def on_alias(node)
      alias_node, source_node = *node

      callback = "on_alias_#{alias_node.type}"

      send(callback, alias_node, source_node) if respond_to?(callback)
    end

    ##
    # Aliases a method.
    #
    # @param [RubyLint::AST::Node] alias_node
    # @param [RubyLint::AST::Node] source_node
    #
    def on_alias_sym(alias_node, source_node)
      method_type = current_scope.method_call_type
      alias_name  = alias_node.name
      source_name = source_node.name
      source      = current_scope.lookup(method_type, source_name)

      current_scope.add(method_type, alias_name, source) if source
    end

    ##
    # Aliases a global variable.
    #
    # @see #on_alias_sym
    #
    def on_alias_gvar(alias_node, source_node)
      alias_name  = alias_node.name
      source_name = source_node.name
      source      = current_scope.lookup(:gvar, source_name)

      # Global variables should be added to the root scope.
      definitions.add(:gvar, alias_name, source) if source
    end

    private

    ##
    # Returns the initial set of definitions to use.
    #
    # @return [RubyLint::Definition::RubyObject]
    #
    def initial_definitions
      parents = [RubyLint::VirtualMachine.global_scope]

      parents << extra_definitions if extra_definitions

      definitions = Definition::RubyObject.new(
        :name          => 'root',
        :type          => :root,
        :parents       => parents,
        :instance_type => :instance
      )

      definitions.add(:keyword, 'self', definitions)

      return definitions
    end

    ##
    # Defines a new module/class based on the supplied node.
    #
    # @param [RubyLint::Node] node
    # @param [Class] definition_builder
    # @param [Hash] options
    #
    def define_module(node, definition_builder, options = {})
      builder    = definition_builder.new(node, current_scope, options)
      definition = builder.build
      scope      = builder.scope
      existing   = scope.lookup(definition.type, definition.name)

      if existing
        definition = existing

        inherit_definition(definition, current_scope)
      else
        definition.add_definition(definition)

        scope.add_definition(definition)
      end

      associate_node(node, definition)

      push_scope(definition)
    end

    ##
    # @return [RubyLint::Definition::RubyObject]
    #
    def current_scope
      return @scopes.last
    end

    ##
    # @return [RubyLint::Definition::RubyObject]
    #
    def previous_scope
      return @scopes[-2]
    end

    ##
    # Associates the given node and defintion with each other.
    #
    # @param [RubyLint::AST::Node] node
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def associate_node(node, definition)
      @associations[node] = definition
    end

    ##
    # Pushes a new scope on the list of available scopes.
    #
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def push_scope(definition)
      unless definition.is_a?(RubyLint::Definition::RubyObject)
        raise(
          ArgumentError,
          "Expected a RubyLint::Definition::RubyObject but got " \
            "#{definition.class} instead"
        )
      end

      @scopes << definition
    end

    ##
    # Removes a scope from the list.
    #
    def pop_scope
      raise 'Trying to pop an empty scope' if @scopes.empty?

      @scopes.pop
    end

    ##
    # Pushes the value of a variable onto the value stack.
    #
    # @param [RubyLint::AST::Node] node
    #
    def push_variable_value(node)
      return if value_stack.empty? || @ignored_nodes.include?(node)

      definition = definition_for_node(node)

      if definition
        value = definition.value ? definition.value : definition

        push_value(value)
      end
    end

    ##
    # Pushes a definition (of a value) onto the value stack.
    #
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def push_value(definition)
      value_stack.push(definition) if definition && !value_stack.empty?
    end

    ##
    # Adds a new variable and value stack.
    #
    def add_stacks
      variable_stack.add_stack
      value_stack.add_stack
    end

    ##
    # Assigns a basic variable.
    #
    # @param [Symbol] type The type of variable.
    # @param [String] name The name of the variable
    # @param [RubyLint::Definition::RubyObject] value
    #
    def assign_variable(type, name, value)
      variable = Definition::RubyObject.new(
        :type          => type,
        :name          => name,
        :value         => value,
        :instance_type => :instance
      )

      buffer_assignment_value(variable.value)

      add_variable(variable)
    end

    ##
    # Adds a variable to the current scope of, if a the variable stack is not
    # empty, add it to the stack instead.
    #
    # @param [RubyLint::Definition::RubyObject] variable
    # @param [RubyLint::Definition::RubyObject] scope
    #
    def add_variable(variable, scope = current_scope)
      if variable_stack.empty?
        scope.add(variable.type, variable.name, variable)
      else
        variable_stack.push(variable)
      end
    end

    ##
    # Creates a primitive value such as an integer.
    #
    # @param [RubyLint::AST::Node] node
    # @param [Hash] options
    #
    def create_primitive(node, options = {})
      builder = DefinitionBuilder::Primitive.new(node, current_scope, options)

      return builder.build
    end

    ##
    # Resets the variable used for storing the last assignment value.
    #
    def reset_assignment_value
      @assignment_value = nil
    end

    ##
    # Returns the value of the last assignment.
    #
    def assignment_value
      return @assignment_value
    end

    ##
    # Stores the value as the last assigned value.
    #
    # @param [RubyLint::Definition::RubyObject] value
    #
    def buffer_assignment_value(value)
      @assignment_value = value
    end

    ##
    # Resets the method assignment/call type.
    #
    def reset_method_type
      @method_type = :instance_method
    end

    ##
    # Performs a conditional assignment.
    #
    # @param [RubyLint::Definition::RubyObject] variable
    # @param [RubyLint::Definition::RubyValue] value
    # @param [TrueClass|FalseClass] bool When set to `true` existing variables
    #  will be overwritten.
    #
    def conditional_assignment(variable, value, bool = true)
      if current_scope.has_definition?(variable.type, variable.name) == bool
        variable.value = value

        current_scope.add_definition(variable)

        buffer_assignment_value(variable.value)
      end
    end

    ##
    # Returns the definition for the given node.
    #
    # @param [RubyLint::AST::Node] node
    # @return [RubyLint::Definition::RubyObject]
    #
    def definition_for_node(node)
      if node.const? and node.children[0]
        definition = resolve_constant_path(node)
      else
        definition = current_scope.lookup(node.type, node.name)
      end

      return definition
    end

    ##
    # Increments the reference amount of a node's definition unless the
    # definition is frozen.
    #
    # @param [RubyLint::AST::Node] node
    #
    def increment_reference_amount(node)
      definition = definition_for_node(node)

      if definition and !definition.frozen?
        definition.reference_amount += 1
      end
    end

    ##
    # Evaluates and returns the value of the given node.
    #
    # @param [RubyLint::AST::Node] node
    # @return [RubyLint::Definition::RubyObject]
    #
    def evaluate_node(node)
      value_stack.add_stack

      iterate(node)

      return value_stack.pop.first
    end

    ##
    # Includes the definition `inherit` in the list of parent definitions of
    # `definition`.
    #
    # @param [RubyLint::Definition::RubyObject] definition
    # @param [RubyLint::Definition::RubyObject] inherit
    #
    def inherit_definition(definition, inherit)
      unless definition.parents.include?(inherit)
        definition.parents << inherit
      end
    end

    ##
    # Extracts all the docstring tags from the documentation of the given
    # node, retrieves the corresponding types and stores them for later use.
    #
    # @param [RubyLint::AST::Node] node
    #
    def buffer_docstring_tags(node)
      return unless comments[node]

      parser = Docstring::Parser.new
      tags   = parser.parse(comments[node].map(&:text))

      @docstring_tags = Docstring::Mapping.new(tags)
    end

    ##
    # Resets the docstring tags collection back to its initial value.
    #
    def reset_docstring_tags
      @docstring_tags = nil
    end

    ##
    # Updates the parents of a definition according to the types of a `@param`
    # tag.
    #
    # @param [RubyLint::Docstring::ParamTag] tag
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def update_parents_from_tag(tag, definition)
      extra_parents = definitions_for_types(tag.types)

      definition.parents.concat(extra_parents)
    end

    ##
    # Creates an "unknown" definition with the given method in it.
    #
    # @param [String] name The name of the method to add.
    # @return [RubyLint::Definition::RubyObject]
    #
    def create_unknown_with_method(name)
      definition = Definition::RubyObject.new(
        :name => 'UnknownType',
        :type => :const
      )

      definition.send("define_#{@method_type}", name)

      return definition
    end

    ##
    # Returns a collection of definitions for a set of YARD types.
    #
    # @param [Array] types
    # @return [Array]
    #
    def definitions_for_types(types)
      definitions = []

      # There are basically two type signatures: either the name(s) of a
      # constant or a method in the form of `#method_name`.
      types.each do |type|
        if type[0] == '#'
          found = create_unknown_with_method(type[1..-1])
        else
          found = lookup_type_definition(type)
        end

        definitions << found if found
      end

      return definitions
    end

    ##
    # Tries to look up the given type/constant in the current scope and falls
    # back to the global scope if it couldn't be found in the former.
    #
    # @param [String] name
    # @return [RubyLint::Definition::RubyObject]
    #
    def lookup_type_definition(name)
      return current_scope.lookup(:const, name) ||
        self.class.global_constant(name)
    end

    ##
    # @param [RubyLint::Docstring::ReturnTag] tag
    # @param [RubyLint::Definition::RubyMethod] definition
    #
    def assign_return_value_from_tag(tag, definition)
      definitions = definitions_for_types(tag.types)

      # THINK: currently ruby-lint assumes methods always return a single type
      # but YARD allows you to specify multiple ones. For now we'll take the
      # first one but there should be a nicer way to do this.
      definition.returns(definitions[0]) if definitions[0]
    end
  end # VirtualMachine
end # RubyLint
