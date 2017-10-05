#!/usr/bin/env ruby
# coding: utf-8
require 'test/unit'
require_relative '../cwl-inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestExpression < Test::Unit::TestCase
  def test_commandline
    begin
      node_bin
    rescue
      skip # if nodejs is not installed
    end
    assert_equal(cwl_inspect("#{CWL_PATH}/expression/expression.cwl", 'commandline'),
                 'echo -A 2 -B baz -C 10 9 8 7 6 5 4 3 2 1')
  end
end
