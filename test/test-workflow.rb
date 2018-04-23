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
    assert_equal("docker run -i --rm --workdir=/private/var/spool/cwl --env=TMPDIR=/tmp --env=HOME=/private/var/spool/cwl -v Foo.java:/private/var/lib/cwl/inputs/Foo.java:ro -v #{Dir.pwd}/tmp:/private/var/lib/cwl/outputs:rw java:7-jdk javac -d #{Dir.pwd}/tmp '/private/var/lib/cwl/inputs/Foo.java'",
                 cwl_inspect(cwl, 'commandline',
                             {
                               :runtime => { 'outdir' => File.absolute_path('tmp') },
                               :args => { 'src' => { 'class' => 'File', 'path' => 'Foo.java'} },
                               :doc_dir => @cwldir,
                             }))
  end

  def test_steps
    assert_equal(['untar', 'compile'],
                 cwl_inspect(@cwl, 'keys(.steps)', { :doc_dir => @cwldir }))
  end

  def test_step_commandline
    assert_equal('tar xf \'$inp\' \'$ex\'',
                 cwl_inspect(@cwl, 'commandline(.steps.untar)', { :args => {}, :doc_dir => @cwldir }))
  end

  def test_step_instantiated_commandline
    assert_equal('tar xf \'foo.tar\' \'bar.java\'',
                 cwl_inspect(@cwl, 'commandline(.steps.untar)',
                             {
                               :runtime => {},
                               :args => { 'inp' => { 'class' => 'File', 'path' => 'foo.tar' }, 'ex' => 'bar.java' },
                               :doc_dir => @cwldir,
                             }))
  end
end
