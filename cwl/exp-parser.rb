#!/usr/bin/env ruby
# coding: utf-8
require 'parslet'

# https://www.commonwl.org/v1.0/CommandLineTool.html#Parameter_references
class ParameterReferenceParser < Parslet::Parser
  rule(:symbol) {
    match(/[[:alnum:]_]/).repeat(1)
  }
  rule(:singleq) {
    str("['") >> (str("'").absent? >> match(/./) | str("\\'")).repeat >> str("']")
  }
  rule(:doubleq) {
    str('["') >> (str('"').absent? >> match(/./) | str('\\"')).repeat >> str('"]')
  }
  rule(:index) {
    str('[') >> match(/[0-9]+/) >> str(']')
  }
  rule(:segment) {
    str('.') >> symbol | singleq | doubleq | index
  }
  rule(:parameter_reference) {
    (str('$(').absent? >> any).repeat.as(:pre) >>
      str('$(') >> (symbol >> segment.repeat).as(:body) >>
      str(')') >> any.repeat.as(:post)
  }
  root(:parameter_reference)
end

if $0 == __FILE__
  p ParameterReferenceParser.new.parse(ARGV.empty? ? 'foo$(inputs.inp.basename).log'
                                       : ARGV.first)
end
