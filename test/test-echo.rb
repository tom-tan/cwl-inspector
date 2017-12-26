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
    assert_equal('v1.0',
                 cwl_inspect(@cwl, '.cwlVersion'))
  end

  def test_id_based_access
    assert_equal('Input string',
                 cwl_inspect(@cwl, '.inputs.input.label'))
  end

  def test_index_based_access
    assert_equal('Input string',
                 cwl_inspect(@cwl, '.inputs.0.label'))
  end

  def test_commandline
    assert_equal('docker run -i --rm docker/whalesay cowsay [ \'$input\' ] > output',
                 cwl_inspect(@cwl, 'commandline'))
  end

  def test_instantiated_commandline
    assert_equal('docker run -i --rm docker/whalesay cowsay \'Hello!\' > output',
                 cwl_inspect(@cwl, 'commandline', nil,
                             { :args => { 'input' => 'Hello!' }, :runtime => {} }))
  end

  def test_root_keys
    assert_equal(['class', 'cwlVersion', 'id', 'baseCommand',
                  'inputs', 'outputs', 'stdout', 'requirements'],
                 cwl_inspect(@cwl, 'keys(.)'))
  end

  def test_keys
    assert_equal(['input'],
                 cwl_inspect(@cwl, 'keys(.inputs)'))
  end
end
