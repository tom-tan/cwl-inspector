#!/usr/bin/env ruby
# coding: utf-8

#
# Copyright (c) 2017 Tomoya Tanjo
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
require 'optparse'
require_relative 'parser'

def walk(cwl, path, default=nil)
  unless path.start_with? '.'
    raise CWLInspectionError, "Invalid path: #{path}"
  end
  if cwl.instance_of? String
    cwl = CommonWorkflowLanguage.load_file(cwl)
  end

  begin
    cwl.walk(path[1..-1].split(/\.|\[|\]\.|\]/))
  rescue CWLInspectionError => e
    if default.nil?
      raise e
    else
      default
    end
  end
end

def keys(file, path)
  obj = walk(file, path)
  obj.keys
end

def docker_command(cwl, runtime, inputs)
  return [[], {}]
  img = if walk(cwl, '.requirements.DockerRequirement', nil)
          walk(cwl, '.requirements.DockerRequirement', nil)
        elsif walk(cwl, '.hints.DockerRequirement', nil) and system('which docker > /dev/null')
          walk(cwl, '.hints.DockerRequirement', nil)
        else
          nil
        end
  if img
    vardir = case RUBY_PLATFORM
             when /darwin|mac os/
               '/private/var'
             when /linux/
               '/var'
             else
               raise "Unsupported platform: #{RUBY_PLATFORM}"
             end
    cmd = [
      'docker', 'run', '-i', '--read-only',
      '--rm', # to be configurable
      "--workdir=#{vardir}/spool/cwl", "--env=HOME=#{vardir}/spool/cwl",
      "--env=TMPDIR=/tmp",
      "--user=#{Process::UID.eid}:#{Process::GID.eid}",
      "-v #{runtime['outdir']}:#{vardir}/spool/cwl",
      "-v #{runtime['tmpdir']}:/tmp",
    ]
    volume_map = {}

    inputs.keep_if{ |k, v|
      # どこかに File か Directory があれば
      v.class_ == 'File' or v.class_ == 'Directory'
    }
  end
end

def construct_args(cwl, vol_map, runtime, inputs, self_)
  walk(cwl, '.arguments', []).to_enum.with_index.map{ |body, idx|
    i = walk(body, '.position', 0)
    [[i, idx], nil]
  }
end

def container_command(cwl, runtime, inputs = nil, self_ = nil, container = :docker)
  case container
  when :docker
    docker_command(cwl, runtime, inputs)
  else
    raise CWLInspectionError, "Unsupported container: #{container}"
  end
end

def commandline(file, runtime = {}, inputs = nil, self_ = nil)
  cwl = CommonWorkflowLanguage.load_file(file)
  docker_cmd, vol_map = container_command(cwl, runtime, inputs, self_, :docker)

  redirect_in = if walk(cwl, '.stdin', nil)
                  fname = cwl.stdin.evaluate(walk(cwl, '.requirements.InlineJavascriptRequirement', false),
                                             inputs, runtime, self_)
                  ['<', fname]
                else
                  []
                end

  redirect_out = if walk(cwl, '.stdout', nil)
                   fname = cwl.stdout.evaluate(walk(cwl, '.requirements.InlineJavascriptRequirement', false),
                                               inputs, runtime, self_)
                   ['>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end

  redirect_err = if walk(cwl, '.stderr', nil)
                   fname = cwl.stderr.evaluate(walk(cwl, '.requirements.InlineJavascriptRequirement', false),
                                               inputs, runtime, self_)
                   ['2>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end

  [
    *docker_cmd,
    *walk(cwl, '.baseCommand', []),
    # *construct_args(cwl, vol_map, settings),
    *redirect_in,
    *redirect_out,
    *redirect_err,
  ].join(' ')
end

def eval_runtime
  {
    'coresMin' => 1,
    'coresMax' => 1,
    'ramMin' => 1024,
    'ramMax' => 1024,
    'tmpdirMin' => 1024,
    'tmpdirMax' => 1024,
    'outdirMin' => 1024,
    'outdirMax' => 1024,
    'tmpdir' => '/tmp',
    'outdir' => File.absolute_path(Dir.pwd),
  }
end

if $0 == __FILE__
  format = :yaml
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} [options] cwl cmd"
  opt.on('-j', '--json', 'Print result in JSON format') {
    format = :json
  }
  opt.on('-y', '--yaml', 'Print result in YAML format (default)') {
    format = :yaml
  }
  opt.parse!(ARGV)

  unless ARGV.length == 2
    puts opt.help
    exit
  end

  file, cmd = ARGV
  unless File.exist? file
    raise CWLInspectionError, "No such file: #{file}"
  end

  fmt = if format == :yaml
          ->(a) { YAML.dump(a) }
        else
          ->(a) { JSON.dump(a) }
        end

  inputs = nil
  runtime = eval_runtime

  ret = case cmd
        when /^\..*/
          fmt.call walk(file, cmd).to_h
        when /^keys\((\..*)\)$/
          fmt.call keys(file, $1)
        when /^commandline$/
          if walk(file, '.class') != 'CommandLineTool'
            raise CWLInspectionError, "#{walk(file, '.class')} is not support `commandline`"
          end
          commandline(file, runtime, inputs)
        else
          raise CWLInspectionError, "Unsupported command: #{cmd}"
        end
  puts ret
end
