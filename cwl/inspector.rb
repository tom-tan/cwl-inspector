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

def keys(file, path, default=[])
  obj = walk(file, path, nil)
  if obj.instance_of?(Array)
    obj
  else
    obj ? obj.keys : default
  end
end

class UninstantiatedVariable
  attr_reader :name

  def initialize(var)
    @name = var
  end
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

def evaluate_input_binding(cwl, binding_, runtime, inputs, self_)
  valueFrom = walk(binding_, '.valueFrom', nil)
  value = if self_.instance_of? UninstantiatedVariable
            valueFrom ? UninstantiatedVariable.new("eval(#{self_.name})") : self_
          elsif valueFrom
            valueFrom.evaluate(walk(cwl, '.requirements.InlineJavascriptRequirement', false),
                               runtime, inputs, self_)
          else
            self_
          end

  pre = walk(binding_, '.prefix', nil)
  ret = case value
        when String, Numeric
          tmp = pre ? [pre, value] : [value]
          walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
        when TrueClass
          pre
        when FalseClass
          # Add nothing
        when CWLFile
          tmp = pre ? [pre, value.path] : [value.path]
          walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
        # when Directory
        when CommandInputArraySchema
          isep = walk(binding_, '.itemSeparator', nil)
          sep = isep.nil? ? true : walk(binding_, '.separate', true)
          isep = isep or ' '

          tmp = pre ? [pre, value.join(isep)] : [value.join(isep)]
          sep ? tmp.join(' ') : tmp.join
        when nil
          # Add nothing
        when UninstantiatedVariable
          tmp = pre ? [pre, self_.name] : [self_.name]
          walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
        else
          isep = walk(binding_, '.itemSeparator', nil)
          sep = isep.nil? ? true : walk(binding_, '.separate', true)
          isep = isep or ' '

          tmp = pre ? [pre, value.keys.join(isep)] : [value.keys.join(isep)] # TODO
          sep ? tmp.join(' ') : tmp.join
        end
  if walk(cwl, '.requirements.ShellCommandRequirement', false) and ret
    walk(binding_, '.shellQuote', true) ? "'#{ret}'" : ret
  else
    unless walk(binding_, '.shellQuote', true)
      raise CWLInspectionError, "`shellQuote' should be used with `ShellCommandRequirement'"
    end
    if ret
      "'#{ret}'"
    end
  end
end

def construct_args(cwl, vol_map, runtime, inputs, self_)
  arr = walk(cwl, '.arguments', []).to_enum.with_index.map{ |body, idx|
    i = walk(body, '.position', 0)
    [[i, idx], evaluate_input_binding(cwl, body, runtime, inputs, nil)]
  }+walk(cwl, '.inputs', []).find_all{ |input|
    walk(input, '.inputBinding', nil)
  }.map{ |input|
    i = walk(input, '.inputBinding.position', 0)
    [[i, input.id], evaluate_input_binding(cwl, input.inputBinding, runtime, inputs, inputs[input.id])]
  }

  arr.sort{ |a, b|
    a0, b0 = a[0], b[0]
    if a0[0] == b0[0]
      a01, b01 = a0[1], b0[1]
      if a01.class == b01.class
        a01 <=> b01
      elsif a01.instance_of? Integer
        -1
      else
        1
      end
    else
      a0[0] <=> b0[0]
    end
  }.map{ |v|
    v[1]
  }.flatten(1)
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
                                             runtime, inputs, self_)
                  ['<', fname]
                else
                  []
                end

  redirect_out = if walk(cwl, '.stdout', nil)
                   fname = cwl.stdout.evaluate(walk(cwl, '.requirements.InlineJavascriptRequirement', false),
                                               runtime, inputs, self_)
                   ['>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end

  redirect_err = if walk(cwl, '.stderr', nil)
                   fname = cwl.stderr.evaluate(walk(cwl, '.requirements.InlineJavascriptRequirement', false),
                                               runtime, inputs, self_)
                   ['2>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end

  [
    *docker_cmd,
    *walk(cwl, '.baseCommand', []),
    *construct_args(cwl, vol_map, runtime, inputs, self_),
    *redirect_in,
    *redirect_out,
    *redirect_err,
  ].join(' ')
end

def eval_runtime
  # TODO
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
  inputs = nil
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} [options] cwl cmd"
  opt.on('-j', '--json', 'Print result in JSON format') {
    format = :json
  }
  opt.on('-y', '--yaml', 'Print result in YAML format (default)') {
    format = :yaml
  }
  opt.on('-i=INPUT', 'Job parameter file for `commandline`') { |inp|
    inputs = YAML.load_file(inp)
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

  if inputs.nil?
    inputs = Hash[keys(file, '.inputs').map{ |inp|
      [inp, UninstantiatedVariable.new("$#{inp}")]
    }]
  end
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
