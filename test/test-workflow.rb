#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'test/unit'
require_relative '../cwl/inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestWorkflow < Test::Unit::TestCase
  def setup
    @cwldir = File.join(CWL_PATH, 'workflow')
    @cwlfile = File.join(@cwldir, '1st-workflow.cwl')
    @runtime = {
      'outdir' => File.absolute_path('tmp'),
      'docdir' => [@cwldir],
      'tmpdir' => '/tmp',
    }
    @vardir = case RUBY_PLATFORM
              when /darwin|mac os/
                '/private/var'
              when /linux/
                '/var'
              else
                raise "Unsupported platform: #{RUBY_PLATFORM}"
              end
    @use_docker = system('which docker > /dev/null')
  end

  def test_arguments
    cwlfile = File.join(@cwldir, 'arguments.cwl')
    cmd = if @use_docker
            "docker run -i --read-only --rm --workdir=#{@vardir}/spool/cwl --env=HOME=#{@vardir}/spool/cwl --env=TMPDIR=/tmp --user=#{Process::UID.eid}:#{Process::GID.eid} -v #{Dir.pwd}/tmp:#{@vardir}/spool/cwl -v /tmp:/tmp -v #{File.expand_path @cwldir}/Foo.java:#{@vardir}/lib/cwl/inputs/Foo.java:ro java:7-jdk \"javac\" \"-d\" \"#{@vardir}/spool/cwl\" \"#{@vardir}/lib/cwl/inputs/Foo.java\""
          else
            sh = case RUBY_PLATFORM
                 when /darwin|mac os/
                   '/bin/bash'
                 else
                   '/bin/sh'
                 end
            "env HOME='#{@runtime['outdir']}' TMPDIR='#{@runtime['tmpdir']}' #{sh} -c 'cd ~ && \"javac\" \"-d\" \"#{@runtime['outdir']}\" \"#{File.expand_path @cwldir}/Foo.java\"'"
          end
    assert_equal(cmd, commandline(cwlfile,
                                  @runtime,
                                  parse_inputs(cwlfile,
                                               {
                                                 'src' => {
                                                   'class' => 'File',
                                                   'path' => 'Foo.java',
                                                 }
                                               },
                                               @runtime['docdir'].first)))
  end

  def test_steps
    cwl = CommonWorkflowLanguage.load_file(@cwlfile)
    assert_equal(['compile', 'untar'], keys(cwl, '.steps').sort)
  end
end
