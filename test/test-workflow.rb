#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'test/unit'
require_relative '../cwl-inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestWorkflow < Test::Unit::TestCase
  def setup
    @cwldir = File.join(CWL_PATH, 'workflow')
    @cwl = YAML.load_file(File.join(@cwldir, '1st-workflow.cwl'))
  end

  def test_arguments
    cwl = YAML.load_file(File.join(@cwldir, 'arguments.cwl'))
    assert_equal('docker run -i --rm java:7-jdk javac -d tmp Foo.java',
                 cwl_inspect(cwl, 'commandline', @cwldir,
                             { :runtime => { 'outdir' => 'tmp' },
                               :args => { 'src' => 'Foo.java' }}))
  end

  def test_steps
    assert_equal(['untar', 'compile'],
                 cwl_inspect(@cwl, 'keys(.steps)', @cwldir))
  end

  def test_step_commandline
    assert_equal('tar xf $inp $ex',
                 cwl_inspect(@cwl, 'commandline(.steps.untar)', @cwldir))
  end

  def test_step_instantiated_commandline
    assert_equal('tar xf foo.tar bar.java',
                 cwl_inspect(@cwl, 'commandline(.steps.untar)', @cwldir,
                             { :runtime => {}, :args => { 'inp' => 'foo.tar', 'ex' => 'bar.java' }}))
  end
end
