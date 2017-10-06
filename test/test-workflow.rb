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

  def test_steps
    assert_equal(cwl_inspect(@cwl, 'keys(.steps)', @cwldir),
                 ['untar', 'compile'])
  end

  def test_step_commandline
    assert_equal(cwl_inspect(@cwl, 'commandline(.steps.untar)', @cwldir),
                 'tar xf $inp $ex')
  end

  def test_step_instantiated_commandline
    assert_equal(cwl_inspect(@cwl, 'commandline(.steps.untar)', @cwldir,
                             { 'inp' => 'foo.tar', 'ex' => 'bar.java' }),
                 'tar xf foo.tar bar.java')
  end
end
