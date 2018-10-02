#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'test/unit'
require_relative '../cwl/inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestExpression < Test::Unit::TestCase
  def setup
    @cwl = File.join(CWL_PATH, 'expression', 'expression.cwl')
    @runtime = {
      'outdir' => File.absolute_path('.'),
      'docdir' => '.',
      'tmpdir' => '/tmp',
    }
    @sh = case RUBY_PLATFORM
          when /darwin|mac os/
            '/bin/bash'
          else
            '/bin/sh'
          end
  end

  def test_commandline
    begin
      node_bin
    rescue
      skip # if nodejs is not installed
    end
    assert_equal("env HOME='#{@runtime['outdir']}' TMPDIR='/tmp' #{@sh} -c 'cd ~ && \"echo\" -A 2 -B \"baz\" -C 10 9 8 7 6 5 4 3 2 1'",
                 commandline(@cwl, @runtime,
                             parse_inputs(@cwl, {}, @runtime)))
  end
end
