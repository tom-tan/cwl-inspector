#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'test/unit'
require_relative '../cwl-inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestEcho < Test::Unit::TestCase
  def setup
    @cwl = YAML.load_file(File.join(CWL_PATH, 'echo', 'echo.cwl'))
  end

  def test_version
    assert_equal(cwl_inspect(@cwl, '.cwlVersion'),
                 'v1.0')
  end

  def test_id_based_access
    assert_equal(cwl_inspect(@cwl, '.inputs.input.label'),
                 'Input string')
  end

  def test_index_based_access
    assert_equal(cwl_inspect(@cwl, '.inputs.0.label'),
                 'Input string')
  end

  def test_commandline
    assert_equal(cwl_inspect(@cwl, 'commandline'),
                 'docker run -i --rm docker/whalesay cowsay [ $input ]')
  end

  def test_instantiated_commandline
    assert_equal(cwl_inspect(@cwl, 'commandline', nil, { 'input' => 'Hello!' }),
                 'docker run -i --rm docker/whalesay cowsay Hello!')
  end

  def test_root_keys
    assert_equal(cwl_inspect(@cwl, 'keys(.)'),
                 ['class', 'cwlVersion', 'id', 'baseCommand',
                  'inputs', 'outputs', 'requirements'])
  end

  def test_keys
    assert_equal(cwl_inspect(@cwl, 'keys(.inputs)'),
                 ['input'])
  end
end
