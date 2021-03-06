# This file was automatically generated, any manual changes will be lost the
# next time this file is generated.
#
# Platform: rbx 2.2.3.n364

RubyLint.registry.register('Fixnum') do |defs|
  defs.define_constant('Fixnum') do |klass|
    klass.inherits(defs.constant_proxy('Integer', RubyLint.registry))
    klass.inherits(defs.constant_proxy('JSON::Ext::Generator::GeneratorMethods::Fixnum', RubyLint.registry))
    klass.inherits(defs.constant_proxy('ImmediateValue', RubyLint.registry))

    klass.define_method('===') do |method|
      method.define_argument('obj')
    end

    klass.define_method('induced_from') do |method|
      method.define_argument('obj')
    end

    klass.define_instance_method('%') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('&') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('*') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('**') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('+') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('-') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('-@')

    klass.define_instance_method('/') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('<') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('<<') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('<=') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('<=>') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('==') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('===') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('>') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('>=') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('>>') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('^') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('__marshal__') do |method|
      method.define_argument('ms')
    end

    klass.define_instance_method('coerce') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('div') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('divide') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('divmod') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('fdiv') do |method|
      method.define_argument('n')
    end

    klass.define_instance_method('imaginary')

    klass.define_instance_method('inspect')

    klass.define_instance_method('modulo') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('power!') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('quof') do |method|
      method.define_argument('n')
    end

    klass.define_instance_method('rdiv') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('rpower') do |method|
      method.define_argument('other')
    end

    klass.define_instance_method('size')

    klass.define_instance_method('to_f')

    klass.define_instance_method('to_s') do |method|
      method.define_optional_argument('base')
    end

    klass.define_instance_method('zero?')

    klass.define_instance_method('|') do |method|
      method.define_argument('o')
    end

    klass.define_instance_method('~')
  end

  defs.define_constant('Fixnum::MAX') do |klass|
    klass.inherits(defs.constant_proxy('Object', RubyLint.registry))

  end

  defs.define_constant('Fixnum::MIN') do |klass|
    klass.inherits(defs.constant_proxy('Object', RubyLint.registry))

  end
end
