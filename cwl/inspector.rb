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
  img = if walk(cwl, '.requirements.DockerRequirement', nil)
          walk(cwl, '.requirements.DockerRequirement.dockerPull', nil)
        elsif walk(cwl, '.hints.DockerRequirement', nil) and system('which docker > /dev/null')
          walk(cwl, '.hints.DockerRequirement.dockerPull', nil)
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
      'docker', 'run', '-i', '--read-only', '--rm',
      "--workdir=#{vardir}/spool/cwl", "--env=HOME=#{vardir}/spool/cwl",
      "--env=TMPDIR=/tmp",
      "--user=#{Process::UID.eid}:#{Process::GID.eid}",
      "-v #{runtime['outdir']}:#{vardir}/spool/cwl",
      "-v #{runtime['tmpdir']}:/tmp",
    ]

    replaced_inputs = Hash[
      walk(cwl, '.inputs', []).map{ |v|
        case v.type.class
        when CWLFile, Directory
          obj = inputs[v.id]
          container_path = File.join(vardir, 'lib', 'cwl', 'inputs', obj.basename)
          cmd.push("-v #{obj.location}:#{container_path}:ro")
          ret = obj.clone
          ret.location = container_path
          [v.id, ret.location]
        when Hash # CommandInputRecordSchema, CommandInputArraySchema, CommandInputUnionSchema
          raise CWLInspectionError, "Unsupported"
        else
          [v.id, inputs[v.id]]
        end
      }]
    cmd.push img
    [cmd, replaced_inputs]
  else
    [[], inputs]
  end
end

def evaluate_input_binding(cwl, type, binding_, runtime, inputs, self_)
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
        when nil
          # Add nothing
        when UninstantiatedVariable
          tmp = pre ? [pre, self_.name] : [self_.name]
          walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
        when Array
          isep = walk(binding_, '.itemSeparator', nil)
          sep = isep.nil? ? true : walk(binding_, '.separate', true)
          isep = (isep or ' ')

          tmp = pre ? [pre, value.join(isep)] : [value.join(isep)]
          sep ? tmp.join(' ') : tmp.join
        when Hash
          case type
          when CommandInputRecordSchema
            # TODO
          when CommandInputEnumSchema
            tmp = pre ? [pre, value] : [value]
            arg1 = walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
            arg2 = evaluate_input_binding(cwl, nil, type.inputBinding, runtime, inputs, value)
            [arg1, arg2].join(' ')
          when CommandInputArraySchema
            # TODO
          when CommandInputUnionSchema
            # TODO
          else
            raise CWLInspectionError, "Unsupported type: #{type}"
          end
        else
          isep = walk(binding_, '.itemSeparator', nil)
          sep = isep.nil? ? true : walk(binding_, '.separate', true)
          isep = (isep or ' ')

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

def construct_args(cwl, runtime, inputs, self_)
  arr = walk(cwl, '.arguments', []).to_enum.with_index.map{ |body, idx|
    i = walk(body, '.position', 0)
    [[i, idx], evaluate_input_binding(cwl, nil, body, runtime, inputs, nil)]
  }+walk(cwl, '.inputs', []).find_all{ |input|
    walk(input, '.inputBinding', nil)
  }.map{ |input|
    i = walk(input, '.inputBinding.position', 0)
    [[i, input.id], evaluate_input_binding(cwl, input.type, input.inputBinding, runtime, inputs, inputs[input.id])]
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
  container_cmd, replaced_inputs = container_command(cwl, runtime, inputs, self_, :docker)

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
    *container_cmd,
    *walk(cwl, '.baseCommand', []),
    *construct_args(cwl, runtime, replaced_inputs, self_),
    *redirect_in,
    *redirect_out,
    *redirect_err,
  ].join(' ')
end

def eval_runtime(file)
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
    'docdir' => [
      File.dirname(File.expand_path file),
      '/usr/share/commonwl',
      '/usr/local/share/commonwl',
      File.join(ENV.fetch('XDG_DATA_HOME', File.join(ENV['HOME'], '.local', 'share')), 'commonwl'),
    ]
  }
end

def parse_inputs(cwl, inputs, runtime)
  input_not_required = walk(cwl, '.inputs', []).all?{ |inp|
    (inp.type.class == CommandInputUnionSchema and
      inp.type.types.find_index{ |obj|
      obj.instance_of?(CWLType) and obj.type == 'null'
     }) or not inp.default.nil?
  }
  if input_not_required or not inputs.nil?
    Hash[walk(cwl, '.inputs', []).map{ |inp|
           [inp.id, parse_object(inp.id, inp.type, inputs.nil? ? nil : inputs.fetch(inp.id, nil),
                                 inp.default, inp.inputBinding.loadContents, runtime)]
         }]
  else
    Hash[keys(cwl, '.inputs', []).map{ |inp|
           [inp.id, UninstantiatedVariable.new("$#{inp.id}")]
         }]
  end
end

def parse_object(id, type, obj, default, loadContents, runtime)
  case type
  when CWLType
    case type.type
    when 'null'
      unless obj.nil? and default.nil?
        raise CWLInspectionError, "Invalid null object: #{obj}"
      end
      obj
    when 'boolean'
      obj = obj.nil? ? default : obj
      unless obj == true or obj == false
        raise CWLInspectionError, "Invalid boolean object: #{obj}"
      end
      obj
    when 'int', 'long'
      obj = obj.nil? ? default : obj
      unless obj.instance_of? Integer
        raise CWLInspectionError, "Invalid #{type.type} object: #{obj}"
      end
      obj
    when 'float', 'double'
      obj = obj.nil? ? default : obj
      unless obj.instance_of? Float
        raise CWLInspectionError, "Invalid #{type.type} object: #{obj}"
      end
      obj
    when 'string'
      obj = obj.nil? ? default : obj
      unless obj.instance_of? String
        raise CWLInspectionError, "Invalid string object: #{obj}"
      end
      obj
    when 'File'
      obj = obj.nil? ? default : obj
      if obj.nil?
        raise CWLInspectionError, "Invalid File object: #{obj}"
      end
      file = CWLFile.load(obj)
      path = file.location.sub %r|^.+//|, ''
      unless File.exist? path
        raise CWLInspectionError, "File not found: #{path}"
      end
      file.evaluate(runtime, loadContents)
    when 'Directory'
      obj = obj.nil? ? default : obj
      if obj.nil?
        raise CWLInspectionError, "Invalid Directory object: #{obj}"
      end
      dir = Directory.load(obj)
      path = dir.location.sub %r|^.+//|, ''
      unless Dir.exist? path
        raise CWLInspectionError, "Directory not found: #{path}"
      end
      dir.evaluate(runtime, nil)
    end
  when CommandInputUnionSchema
    idx = type.types.find_index{ |t|
      begin
        parse_object(id, t, obj, default, loadContents, runtime)
        true
      rescue CWLInspectionError
        false
      end
    }
    if idx.nil?
      raise CWLInspectionError, "Invalid object: #{obj}"
    end
    parse_object("#{id}[#{idx}]", type.types[idx], obj, default, loadContents, runtime)
  when CommandInputRecordSchema
    raise CWLInspectionError, "Unsupported input type: #{type.class}"
    # unless obj.instance_of? Hash
    #   raise CWLInspectionError, "#{input.id} must be a record type of #{input.type.fields.map{ |f| f.type}.join(', ')}"
    # end
    # fields = input.fields
    # Hash[fields.map{ |f|
    #   unless obj.include? f.name
    #     raise CWLInspectionError, "#{input.id} must have a record `#{f.name}`"
    #   end
    #   [f.name, parse_object("id.#{f.name}", f.type, obj[f.name], nil, loadContents, runtime)]
    # }]
  when CommandInputEnumSchema
    raise CWLInspectionError, "Unsupported input type: #{type.class}"
    # unless obj.instance_of?(String) and input.symbols.include? obj
    #   raise CWLInspectionError, "#{input.id} requires must be #{input.symbols.join(', ')}"
    # end
    # obj
  when CommandInputArraySchema
    t = type.items
    unless obj.instance_of? Array
      raise CWLInspectionError, "#{input.id} requires array of #{t} type"
    end
    obj.map{ |o|
      parse_object(id, t, o, nil, loadContents, runtime)
    }
  else
    raise CWLInspectionError, "Unsupported type: #{type.class}"
  end
end

if $0 == __FILE__
  format = :yaml
  inp_obj = nil
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} [options] cwl cmd"
  opt.on('-j', '--json', 'Print result in JSON format') {
    format = :json
  }
  opt.on('-y', '--yaml', 'Print result in YAML format (default)') {
    format = :yaml
  }
  opt.on('-i=INPUT', 'Job parameter file for `commandline`') { |inp|
    inp_obj = if inp.end_with? '.json'
                open(inp) { |f|
                  JSON.load(f)
                }
              else
                YAML.load_file(inp)
              end
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

  runtime = eval_runtime(file)
  inputs = parse_inputs(file, inp_obj, runtime)

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
