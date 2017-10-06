#!/usr/bin/env ruby
# coding: utf-8
require 'test/unit'
require_relative '../cwl-inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestWorkflow < Test::Unit::TestCase
  def test_steps
    assert_equal(cwl_inspect("#{CWL_PATH}/workflow/1st-workflow.cwl", 'keys(.steps)'),
                 ['untar', 'compile'])
  end

  def test_step_commandline
    assert_equal(cwl_inspect("#{CWL_PATH}/workflow/1st-workflow.cwl",
                             'commandline(.steps.untar)'),
                 'tar xf $inp $ex')
  end

  def test_step_instantiated_commandline
    assert_equal(cwl_inspect("#{CWL_PATH}/workflow/1st-workflow.cwl",
                             'commandline(.steps.untar)',
                             { 'inp' => 'foo.tar', 'ex' => 'bar.java' }),
                 'tar xf foo.tar bar.java')
  end
end
