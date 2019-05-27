#!/usr/bin/env ruby
# coding: utf-8
# frozen_string_literal: true

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
require 'etc'
require 'optparse'
require_relative 'parser'

def keys(file, path, default = [])
  obj = walk(file, path, nil)
  if obj.instance_of?(Array)
    obj.keys
  else
    obj ? obj.keys : default
  end
end

def get_requirement(cwl, req, default = nil)
  walk(cwl, ".requirements.#{req}",
       walk(cwl, ".hints.#{req}", default))
end

def docker_requirement(cwl)
  docker_available = system('which docker > /dev/null')
  if walk(cwl, '.requirements.DockerRequirement')
    unless docker_available
      raise CWLInspectionError, 'Docker required but not found'
    end
    walk(cwl, '.requirements.DockerRequirement')
  elsif walk(cwl, '.hints.DockerRequirement') and docker_available
    walk(cwl, '.hints.DockerRequirement')
  else
    nil
  end
end

def docker_command(cwl, runtime, inputs)
  dockerReq = docker_requirement(cwl)
  img = if dockerReq
          dockerReq.dockerPull
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
    envReq = get_requirement(cwl, 'EnvVarRequirement')
    envArgs = (envReq ? envReq.envDef : []).map{ |e|
      val = e.envValue.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                inputs, runtime, nil)
      "--env=#{e.envName}='#{val}'"
    }
    workdir = (dockerReq.dockerOutputDirectory or "#{vardir}/spool/cwl")
    cmd = [
      'docker', 'run', '-i', '--read-only', '--rm',
      "--workdir=#{workdir}", "--env=HOME=#{workdir}",
      '--env=TMPDIR=/tmp', *envArgs,
      "--user=#{Process::UID.eid}:#{Process::GID.eid}",
      "-v #{runtime['outdir']}:#{workdir}",
      "-v #{runtime['tmpdir']}:/tmp",
    ]
    replaced_runtime = Hash[
      runtime.map{ |k, v|
        case k
        when 'outdir'
          [k, workdir]
        when 'tmpdir'
          [k, '/tmp']
        else
          [k, v]
        end
      }
    ]

    replaced_inputs = Hash[
      walk(cwl, '.inputs', []).map{ |v|
        inp, vols = dockerized(inputs[v.id], v.type, vardir)
        cmd.push(*vols)
        [v.id, inp]
      }]
    cmd.push img
    [cmd, replaced_inputs, replaced_runtime]
  else
    [[], inputs, runtime]
  end
end

def dockerized(input, type, vardir)
  case type
  when CWLType
    case type.type
    when 'File', 'Directory'
      container_path = File.join(vardir, 'lib', 'cwl', 'inputs', input.basename)
      vol = ["-v #{input.path}:#{container_path}:ro"]
      ret = input.clone
      ret.path = container_path
      ret.location = 'file://'+ret.path
      if type.type == 'File' and not input.secondaryFiles.empty?
        sec_, vols = input.secondaryFiles.map{ |sec|
          dockerized(sec, guess_type(sec), vardir)
        }.transpose.map{ |r| r.flatten }
        ret.secondaryFiles = sec_
        vol.push(*vols)
      end
      [ret, vol]
    else
      [input, []]
    end
  when CommandInputRecordSchema
    vols = []
    kvs = []
    input.fields.each{ |k, v|
      idx = type.fields.find_index{ |f| f.name == k }
      inp, vol = dockerized(v, type.fields[idx], vardir)
      kvs.push([k, inp])
      vols.push(*vols)
    }
    [CWLRecordValue.new(Hash[kvs]), vols]
  when CommandInputEnumSchema
    [input, []]
  when CommandInputArraySchema
    unless input.instance_of? Array
      raise CWLInspectionError, "Array expected but actual: #{input.class}"
    end
    ret = input.map{ |inp|
      dockerized(inp, type.items, vardir)
    }.transpose.map{ |r| r.flatten }
    ret.empty? ? [ret, []] : ret
  else
    [input, []]
  end
end

def construct_args(cwl, runtime, inputs, self_)
  # 4.1 (1)
  arguments = walk(cwl, '.arguments', []).to_enum.with_index.map{ |body_, idx|
    i = walk(body_, '.position', 0)
    body = if body_.instance_of? String
             CommandLineBinding.load({ 'valueFrom' => body_ },
                                     runtime['docdir'].first, {}, {})
           else
             body_
           end
    {
      'key' => [i, idx],
      'binding' => body,
      'self' => nil,
      'type' => nil,
    }
  }

  # 4.1 (2), (3)
  inps_ = walk(cwl, '.inputs', []).map{ |inp|
    traverse_inputs(inp.id, inp, runtime, inputs.fetch(inp.id, nil))
  }.flatten.compact.map{ |inp|
    i = inp['inputBinding'].position ? inp['inputBinding'].position : 0
    {
      'key' => [i, inp['id']],
      'binding' => inp['inputBinding'],
      'self' => inp['self'],
      'type' => inp['type'],
    }
  }

  # 4.1 (4)
  sorted = binding_sort(arguments+inps_)

  # 4.1 (5)
  ret = sorted.map{ |obj|
    apply_rule(obj['binding'], obj['type'], cwl, inputs, runtime, obj['self'])
  }

  ret.join(' ')
end

def traverse_inputs(id, arg, runtime, self_)
  if arg.inputBinding
    {
      'id' => id,
      'inputBinding' => arg.inputBinding,
      'self' => self_,
      'type' => arg.type,
    }
  elsif arg.type.instance_of? CWLType
    nil
  elsif arg.type.instance_of? CommandInputUnionSchema
    clb = arg.dup
    clb.type = self_.type
    traverse_inputs(id, clb, runtime, self_.value)
  else
    type = arg.type
    case type.type
    when 'record'
      ret = type.fields.map{ |f|
        traverse_inputs(f.name, f, runtime, self_.fields.fetch(f.name, nil))
      }.flatten.compact
      ret.empty? ? nil : ret
    when 'enum'
      if type.inputBinding
        {
          'id' => id,
          'inputBinding' => type.inputBinding,
          'self' => self_,
          'type' => CWLType.load('string', nil, {}, {}),
        }
      end
    when 'array'
      # To be clarified for both cases
      if type.inputBinding
        self_.to_enum.with_index.map{ |s, idx|
          {
            'id' => idx,
            'inputBinding' => type.inputBinding,
            'self' => s,
            'type' => type.items,
          }
        }
      else
        ret = self_.to_enum.with_index.map{ |s, idx|
          traverse_inputs(idx, CommandInputParameter.load({
                                                            'id' => idx.to_s,
                                                            'type' => type.items.to_h,
                                                          }, runtime['docdir'].first, {}, {}),
                          runtime, s)
        }.flatten.compact
        ret.empty? ? nil : ret
      end
    else
      raise "Unknown type: #{type.to_h}"
    end
  end
end

def binding_sort(arr)
  arr.sort{ |a, b|
    a0, b0 = a['key'], b['key']
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
    v.select{ |k, _|
      k != 'key'
    }
  }
end

def apply_rule(binding_, type_, cwl, inputs, runtime, self_)
  if type_.instance_of? CommandInputUnionSchema
    return apply_rule(binding_, self_.type, cwl, inputs, runtime, self_.value)
  elsif type_.instance_of?(CWLType) and type_.type == 'null'
    return nil
  end

  value, type = if self_.instance_of? UninstantiatedVariable
                  v = binding_.valueFrom ? UninstantiatedVariable.new("eval(#{self_.name})") : self_
                  [v, type_]
                elsif binding_.valueFrom
                  v = binding_.valueFrom.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                                  inputs, runtime, self_)
                  [v, guess_type(v)]
                else
                  t = if type_.nil? or
                        (type_.instance_of?(CWLType) and type_.type == 'Any')
                        guess_type(self_)
                      else
                        type_
                      end
                  [self_, t]
                end
  shellQuote = if get_requirement(cwl, 'ShellCommandRequirement')
                 walk(binding_, '.shellQuote', true)
               else
                 true
               end

  pre = walk(binding_, '.prefix')
  if value.instance_of? UninstantiatedVariable
    name = shellQuote ? %!"#{self_.name}"! : self_.name
    tmp = pre ? [pre, name] : [name]
    return walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
  end

  case type
  when CWLType
    case type.type
    when 'null'
      nil
    when 'boolean'
      if value
        pre
      end
    when 'int', 'long', 'float', 'double'
      tmp = pre ? [pre, value] : [value]
      walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
    when 'string'
      val = shellQuote ? %!"#{value.gsub(/"/, '\\"')}"! : value
      tmp = pre ? [pre, val] : [val]
      walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
    when 'File', 'Directory'
      tmp = pre ? [pre, %!"#{value.path}"!] : [%!"#{value.path}"!]
      walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
    else
      raise CWLInspectionError, "Unsupported type: #{type}"
    end
  when CommandInputRecordSchema
    raise CWLInspectionError, "Unsupported value: #{obj}:#{type}" unless value.instance_of? CWLRecordValue
    # 4.1 (2), (3)
    inps = value.fields.map{ |f, v_|
      idx = type.fields.index{ |fi| fi.name == f }
      traverse_inputs(f, type.fields[idx], runtime, v_)
    }.flatten.compact.map{ |inp|
      i = inp['inputBinding'].position ? inp['inputBinding'].position : 0
      {
        'key' => [i, inp['id']],
        'binding' => inp['inputBinding'],
        'self' => inp['self'],
        'type' => inp['type'],
      }
    }

    # 4.1 (4)
    sorted = binding_sort(inps)

    # 4.1 (5)
    fields = sorted.map{ |obj|
      apply_rule(obj['binding'], obj['type'], cwl, inputs, runtime, obj['self'])
    }

    # separate do nothing with record types
    if pre
      (pre+fields).join(' ')
    else
      fields.join(' ')
    end
  when CommandInputEnumSchema
    tmp = pre ? [pre, value] : [value]
    arg1 = walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
    # To be clarified
    arg2 = if type.inputBinding
             apply_rule(type.inputBinding, CWLType.load('string', nil, {}, {}),
                        cwl, inputs, runtime, value)
           end
    [arg1, arg2].compact.join(' ')
  when CommandInputArraySchema
    if value.empty?
      return nil
    end
    isep = walk(binding_, '.itemSeparator', nil)
    sep = isep.nil? ? true : walk(binding_, '.separate', true)
    isep = (isep or ' ')

    vals = value.map{ |v_|
      elem_binding = if type.inputBinding
                       type.inputBinding
                     else
                       CommandLineBinding.load({}, runtime['docdir'].first, {}, {})
                     end
      apply_rule(elem_binding, type.items, cwl, inputs, runtime, v_)
    }
    tmp = pre ? [pre, vals.join(isep)] : [vals.join(isep)]
    sep ? tmp.join(' ') : tmp.join
  when CommandInputUnionSchema
    raise CWLInspectionError, 'Internal error: this statement should not be executed'
  else
    raise CWLInspectionError, "Unsupported type: #{value}:#{type}:#{value}"
  end
end

def container_command(cwl, runtime, inputs = nil, self_ = nil, container = :docker)
  case container
  when :docker
    docker_command(cwl, runtime, inputs)
  else
    raise CWLInspectionError, "Unsupported container: #{container}"
  end
end

def commandline(cwl, runtime = {}, inputs = nil, self_ = nil)
  if cwl.instance_of? String
    cwl = CommonWorkflowLanguage.load_file(cwl)
  end
  container, replaced_inputs, replaced_runtime = container_command(cwl, runtime, inputs, self_, :docker)
  use_js = get_requirement(cwl, 'InlineJavascriptRequirement', false)

  redirect_in = if walk(cwl, '.stdin')
                  fname = cwl.stdin.evaluate(use_js, inputs, runtime, self_)
                  ['<', fname]
                else
                  []
                end

  redirect_out = if walk(cwl, '.stdout')
                   fname = cwl.stdout.evaluate(use_js, inputs, runtime, self_)
                   ['>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end

  redirect_err = if walk(cwl, '.stderr')
                   fname = cwl.stderr.evaluate(use_js, inputs, runtime, self_)
                   ['2>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end
  envArgs = if docker_requirement(cwl).nil?
              req = get_requirement(cwl, 'EnvVarRequirement')
              ['env', "HOME='#{runtime['outdir']}'", "TMPDIR='#{runtime['tmpdir']}'"]+(req ? req.envDef : []).map{ |e|
                val = e.envValue.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                          inputs, runtime, nil)
                "#{e.envName}='#{val}'"
              }
            else
              []
            end

  command = walk(cwl, '.baseCommand', []).map{ |cmd|
    %!"#{cmd}"!
  }.join(' ')+' '+construct_args(cwl, replaced_runtime, replaced_inputs, self_)

  shell = case RUBY_PLATFORM
          when /darwin|mac os/
            # sh in macOS has an issue in the `echo` command.
            docker_requirement(cwl).nil? ? '/bin/bash' : '/bin/sh'
          when /linux/
            '/bin/sh'
          else
            raise "Unsupported platform: #{RUBY_PLATFORM}"
          end

  cmd = if get_requirement(cwl, 'ShellCommandRequirement', false) or
          docker_requirement(cwl).nil?
          [shell, '-c',
           "'" + [
             docker_requirement(cwl).nil? ? 'cd ~' : nil,
             command.gsub(/'/) { "'\\''" }
           ].compact.join(' && ') + "'" ]
        else
          [
            docker_requirement(cwl).nil? ? 'cd ~' : nil,
            command,
          ].compact.join(' && ')
        end
  [
    *container,
    *envArgs,
    cmd,
    *redirect_in,
    *redirect_out,
    *redirect_err,
  ].compact.join(' ')
end

def eval_runtime(cwl, inputs, outdir, tmpdir)
  runtime = {
    'tmpdir' => tmpdir,
    'outdir' => outdir,
    'docdir' => [
      cwl.instance_of?(String) ? File.dirname(File.expand_path cwl) : Dir.pwd,
      '/usr/share/commonwl',
      '/usr/local/share/commonwl',
      File.join(ENV.fetch('XDG_DATA_HOME',
                          File.join(ENV['HOME'], '.local', 'share')),
                'commonwl'),
    ],
  }

  use_js = get_requirement(cwl, 'InlineJavascriptRequirement', false)
  reqs = get_requirement(cwl, 'ResourceRequirement')
  is_hints = if walk(cwl, ".requirements.#{req}")
               false
             elsif walk(cwl, ".hints.#{req}", default)
               true
             end

  can_eval = inputs.values.find_index{ |v| v.instance_of? UninstantiatedVariable }.nil?

  # cores
  coresMin = (reqs and reqs.coresMin)
  if coresMin.instance_of?(Expression)
    coresMin = if can_eval
                 coresMin.evaluate(use_js, inputs, runtime, nil)
               end
  end
  coresMax = (reqs and reqs.coresMax)
  if coresMax.instance_of?(Expression)
    coresMax = if can_eval
                 coresMax.evaluate(use_js, inputs, runtime, nil)
               end
  end
  raise 'Invalid ResourceRequirement' if not coresMin.nil? and not coresMax.nil? and coresMax < coresMin
  coresMin = coresMax if coresMin.nil?
  coresMax = coresMin if coresMax.nil?
  ncores = Etc.nprocessors
  runtime['cores'] = if coresMin.nil? and coresMax.nil?
                       ncores
                     else
                       if ncores < coresMin
                         is_hints ? ncores : nil
                       else
                         [ncores, coresMax].min
                       end
                     end

  # mem
  ramMin = (reqs and reqs.ramMin)
  if ramMin.instance_of?(Expression)
    ramMin = if can_eval
               ramMin.evaluate(use_js, inputs, runtime, nil)
             end
  end
  ramMax = (reqs and reqs.ramMax)
  if ramMax.instance_of?(Expression)
    ramMax = if can_eval
               ramMax.evaluate(use_js, inputs, runtime, nil)
             end
  end
  raise 'Invalid ResourceRequirement' if not ramMin.nil? and not ramMax.nil? and ramMax < ramMin
  ramMin = ramMax if ramMin.nil?
  ramMax = ramMin if ramMax.nil?
  ram = 1024 # default value in cwltool
  runtime['ram'] = if ramMin.nil? and ramMax.nil?
                     ram
                   else
                     if ram < ramMin
                       is_hints ? ram : nil
                     else
                       [ram, ramMax].min
                     end
                   end
  runtime
end

def parse_inputs(cwl, inputs, docdir)
  input_not_required = walk(cwl, '.inputs', []).all?{ |inp|
    (inp.type.class == CommandInputUnionSchema and
      inp.type.types.find_index{ |obj|
       obj.instance_of?(CWLType) and obj.type == 'null'
     }) or not inp.default.instance_of?(InvalidValue)
  }
  if inputs.nil? and input_not_required
    inputs = {}
  end
  if inputs.nil?
    Hash[walk(cwl, '.inputs', []).map{ |inp|
           [inp.id, UninstantiatedVariable.new("$#{inp.id}")]
         }]
  else
    invalids = Hash[(inputs.keys-walk(cwl, '.inputs', []).map{ |inp| inp.id }).map{ |k|
                      [k, InvalidVariable.new(k)]
                    }]
    valids = Hash[walk(cwl, '.inputs', []).map{ |inp|
                    [inp.id, parse_object(inp.id, inp.type, inputs.fetch(inp.id, nil),
                                          inp.default, walk(inp, '.inputBinding.loadContents', false),
                                          walk(inp, '.secondaryFiles', []),
                                          cwl, docdir)]
                  }]
    invalids.merge(valids)
  end
end

def parse_object(id, type, obj, default, loadContents, secondaryFiles, cwl, docdir, outdir = nil)
  if type.nil?
    type = guess_type(obj)
  elsif type.instance_of?(CWLType) and type.type == 'Any'
    if obj.nil? and (default.instance_of?(InvalidValue) or default.nil?)
      raise CWLInspectionError, '`Any` type requires non-null object'
    end
    v = if default.instance_of?(InvalidValue)
          obj
        else
          obj or default
        end
    type = guess_type(v)
  end

  case type
  when CWLType
    case type.type
    when 'null'
      unless obj.nil? or default.nil?
        raise CWLInspectionError, "Invalid null object: #{obj}"
      end
      obj
    when 'boolean'
      obj = if default.instance_of?(InvalidValue)
              obj
            else
              obj.nil? ? default : obj
            end
      unless obj.instance_of?(TrueClass) or obj.instance_of?(FalseClass)
        raise CWLInspectionError, "Invalid boolean object: #{obj}"
      end
      obj
    when 'int', 'long'
      obj = if default.instance_of?(InvalidValue)
              obj
            else
              obj.nil? ? default : obj
            end
      unless obj.instance_of? Integer
        raise CWLInspectionError, "Invalid #{type.type} object: #{obj}"
      end
      obj
    when 'float', 'double'
      obj = if default.instance_of?(InvalidValue)
              obj
            else
              obj.nil? ? default : obj
            end
      unless obj.instance_of?(Float) or obj.instance_of?(Integer)
        raise CWLInspectionError, "Invalid #{type.type} object: #{obj}"
      end
      obj.to_f
    when 'string'
      obj = if default.instance_of?(InvalidValue)
              obj
            else
              obj.nil? ? default : obj
            end
      unless obj.instance_of? String
        raise CWLInspectionError, "Invalid string object: #{obj}"
      end
      obj
    when 'File'
      if obj.nil? and (default.nil? or default.instance_of?(InvalidValue))
        raise CWLInspectionError, "Invalid File object: #{obj}"
      end
      dockerReq = docker_requirement(cwl)
      file = if dockerReq
               vardir = case RUBY_PLATFORM
                        when /darwin|mac os/
                          '/private/var'
                        when /linux/
                          '/var'
                        else
                          raise "Unsupported platform: #{RUBY_PLATFORM}"
                        end
               workdir = (dockerReq.dockerOutputDirectory or "#{vardir}/spool/cwl")
               if obj.nil?
                 default
               else
                 unless obj.instance_of?(Hash) and obj.fetch('class', '') == 'File'
                   raise CWLInspectionError, "Invalid file object: #{obj}"
                 end
                 o = obj.dup
                 o['path'] = obj['path'].sub(%r!^(file://)?#{workdir}!, "\\1#{outdir}") if o.include? 'path'
                 o['location'] = obj['location'].sub(%r!^(file://)?#{workdir}!, "\\1#{outdir}") if o.include? 'location'
                 CWLFile.load(o, docdir, {}, {})
               end
             else
               if obj.nil?
                 default
               else
                 unless obj.instance_of?(Hash) and obj.fetch('class', '') == 'File'
                   raise CWLInspectionError, "Invalid file object: #{obj}"
                 end
                 CWLFile.load(obj, docdir, {}, {})
               end
             end
      unless secondaryFiles.empty?
        file.secondaryFiles = secondaryFiles.map{ |sec|
          listSecondaryFiles(file, sec, {}, { 'docdir' => [docdir] },
                             get_requirement(cwl, 'InlineJavascriptRequirement'))
        }.flatten
      end
      file.evaluate(docdir, loadContents)
    when 'Directory'
      if obj.nil? and (default.nil? or default.instance_of?(InvalidValue))
        raise CWLInspectionError, "Invalid Directory object: #{obj}"
      end
      dir = if dockerReq
              vardir = case RUBY_PLATFORM
                       when /darwin|mac os/
                         '/private/var'
                       when /linux/
                         '/var'
                       else
                         raise "Unsupported platform: #{RUBY_PLATFORM}"
                       end
              workdir = (dockerReq.dockerOutputDirectory or "#{vardir}/spool/cwl")
              if obj.nil?
                default
              else
                unless obj.instance_of?(Hash) and obj.fetch('class', '') == 'Directory'
                  raise CWLInspectionError, "Invalid Directory object: #{obj}"
                end
                o = obj.dup
                o['path'] = obj['path'].sub(%r!^(file://)?#{workdir}!, "\\1#{outdir}") if o.include? 'path'
                o['location'] = obj['location'].sub(%r!^(file://)?#{workdir}!, "\\1#{outdir}") if o.include? 'location'
                Directory.load(o, docdir, {}, {})
              end
            else
              if obj.nil?
                default
              else
                unless obj.instance_of?(Hash) and obj.fetch('class', '') == 'Directory'
                  raise CWLInspectionError, "Invalid Directory object: #{obj}"
                end
                Directory.load(obj, docdir, {}, {})
              end
            end
      dir.evaluate(docdir, nil)
    end
  when CommandInputUnionSchema, InputUnionSchema
    idx = type.types.find_index{ |t|
      begin
        parse_object(id, t, obj, default, loadContents, secondaryFiles, cwl, docdir)
        true
      rescue CWLInspectionError
        false
      end
    }
    if idx.nil?
      raise CWLInspectionError, "Invalid object: #{obj} of type #{type.to_h}"
    end
    CWLUnionValue.new(type.types[idx],
                      parse_object("#{id}[#{idx}]", type.types[idx], obj, default,
                                   loadContents, secondaryFiles, cwl, docdir))
  when CommandInputRecordSchema, InputRecordSchema
    obj = obj.nil? ? default : obj
    CWLRecordValue.new(Hash[type.fields.map{ |f|
                              [f.name, parse_object(nil, f.type, obj.fetch(f.name, nil), InvalidValue.new,
                                                    loadContents, secondaryFiles, cwl, docdir)]
                            }])
  when CommandInputEnumSchema, InputEnumSchema
    unless obj.instance_of?(String) and type.symbols.include? obj
      raise CWLInspectionError, "Unknown enum value #{obj}: valid values are #{type.symbols}"
    end
    obj.to_sym
  when CommandInputArraySchema, InputArraySchema
    t = type.items
    unless obj.instance_of? Array
      raise CWLInspectionError, "#{input.id} requires array of #{t} type"
    end
    obj.map{ |o_|
      parse_object(id, t, o_, InvalidValue.new, loadContents, secondaryFiles, cwl, docdir)
    }
  else
    raise CWLInspectionError, "Unsupported type: #{type.class}"
  end
end

def list(cwl, runtime, inputs)
  if cwl.instance_of? String
    cwl = CommonWorkflowLanguage.load_file(file)
  end
  dir = runtime['outdir']

  if File.exist? File.join(dir, 'cwl.output.json')
    json = open(File.join(dir, 'cwl.output.json')) { |f|
      JSON.load(f)
    }
    Hash[json.each.map{ |k, v|
           [k,
            parse_object(k, nil, v, nil, false, [], cwl,
                         runtime['docdir'].first, dir).to_h]
         }]
  else
    Hash[walk(cwl, '.outputs', []).map { |o|
           [o.id, list_(cwl, o, runtime, inputs).to_h]
         }]
  end
end

def list_(cwl, output, runtime, inputs)
  type = output.type
  use_js = get_requirement(cwl, 'InlineJavascriptRequirement', false)

  case type
  when Stdout
    fname = walk(cwl, '.stdout')
    evaled = fname.evaluate(use_js, inputs, runtime, nil)
    dir = runtime['outdir']
    location = if evaled.end_with? '.stdout'
                 File.join(dir, Dir.glob('*.stdout', base: dir).first)
               else
                 File.join(dir, evaled)
               end
    file = CWLFile.load({
                          'class' => 'File',
                          'location' => 'file://'+location,
                        }, runtime['docdir'].first, {}, {})
    File.exist?(location) ? file.evaluate(runtime['docdir'].first, false) : file
  when Stderr
    fname = walk(cwl, '.stderr')
    evaled = fname.evaluate(use_js, inputs, runtime, nil)
    dir = runtime['outdir']
    location = if evaled.end_with? '.stderr'
                 File.join(dir, Dir.glob('*.stderr', base: dir).first)
               else
                 File.join(dir, evaled)
               end
    file = CWLFile.load({
                          'class' => 'File',
                          'location' => 'file://'+location,
                        }, runtime['docdir'].first, {}, {})
    File.exist?(location) ? file.evaluate(runtime['docdir'].first, false) : file
  else
    if type.instance_of?(CWLType) and type.type == 'null'
      return nil
    end
    oBinding = output.outputBinding
    evaled = if oBinding
               loadContents = oBinding.loadContents
               dir = runtime['outdir']
               files = oBinding.glob.map{ |g|
                 pats = g.evaluate(use_js, inputs, runtime, nil)
                 pats = pats.instance_of?(Array) ? pats : [pats]
                 pats.map{ |p|
                   Dir.glob(p, base: dir).map{ |f|
                     path = File.expand_path(f, dir)
                     if File.directory? path
                       Directory.load({
                                        'class' => 'Directory',
                                        'location' => 'file://'+path,
                                      }, runtime['docdir'].first, {}, {}) # TODO
                     else
                       CWLFile.load({
                                      'class' => 'File',
                                      'location' => 'file://'+path,
                                    }, runtime['docdir'].first, {}, {}) # TODO
                     end
                   }.map{ |f|
                     f.evaluate(runtime['docdir'].first, loadContents)
                   }.sort_by{ |f| f.basename }
                 }
               }.flatten
               if oBinding.outputEval
                 oBinding.outputEval.evaluate(use_js, inputs, runtime, files)
               else
                 files
               end
             else
               nil
             end

    type = output.type
    if type.instance_of?(CWLType) and (type.type == 'File' or
                                       type.type == 'Directory')
      ret = evaled.first
      if type.type == 'File'
        if walk(output, '.format', nil)
          ret.format = output.format.evaluate(use_js, inputs, runtime)
        end
        unless walk(output, '.secondaryFiles', []).empty?
          ret.secondaryFiles = output.secondaryFiles.map{ |sec|
            listSecondaryFiles(ret, sec, inputs, runtime, use_js)
          }.flatten
        end
      end
      ret
    elsif type.instance_of?(CommandOutputRecordSchema)
      if evaled
        evaled
      else
        CWLRecordValue.new(Hash[type.fields.map{ |f|
                                  [f.name, list_(cwl, f, runtime, inputs)]
                                }])
      end
    elsif type.instance_of?(CommandOutputArraySchema) and
         (type.items == 'File' or type.items == 'Directory')
      ret = evaled
      if type.items == 'File' and not output.format.nil?
        ret.map{ |f|
          f.format = output.format.evaluate(use_js, inputs, runtime)
        }
      end
      ret
    elsif type.instance_of?(CommandOutputUnionSchema) and
         type.types.any?{ |t| t.type == 'File' or t.type == 'Directory' }
      if type.types.include?(CWLType.new('null')) and evaled.empty?
        CWLType.new('null')
      else
        evaled.first
      end
    else
      # TODO
      evaled
    end
  end
end

def listSecondaryFiles(file, sec, inputs, runtime, use_js)
  case sec
  when String
    glob = if sec.match(/^(\^+)(.+)$/)
             num, ext = $1.length, $2
             r = file.basename
             num.times{ r = File.basename(r, '.*') }
             r+ext
           else
             sec
           end
    Dir.glob("*#{glob}", base: file.dirname).map{ |f|
      path = File.expand_path(f, file.dirname)
      if File.directory? path
        Directory.load({
                         'class' => 'Directory',
                         'location' => 'file://'+path,
                       }, file.dirname, {}, {})
      else
        CWLFile.load({
                       'class' => 'File',
                       'location' => 'file://'+path,
                     }, file.dirname, {}, {})
      end
    }
  when Expression
    evaled = sec.evaluate(use_js, inputs, runtime, file)
    unless evaled.instance_of? Array
      evaled = [evaled]
    end
    evaled.map{ |e|
      if e.instance_of? CWLUnionValue
        e = e.value
      end
      case e
      when String
        CWLFile.load({
                       'class' => 'File',
                       'path' => e,
                     }, file.dirname, {}, {})
      when CWLFile, Directory
        e
      else
        raise CWLInspectionError, "Unknow evaled secondary File type: #{e.class}"
      end
    }
  end
end

if $0 == __FILE__
  format = :yaml
  inp_obj = nil
  outdir = File.absolute_path Dir.pwd
  tmpdir = '/tmp'
  do_preprocess = true
  do_eval = false
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
  opt.on('--outdir=dir') { |dir|
    outdir = File.expand_path dir
  }
  opt.on('--tmpdir=dir') { |dir|
    tmpdir = File.expand_path dir
  }
  opt.on('--without-preprocess') {
    do_preprocess = false
  }
  opt.on('--evaluate-expressions') {
    do_eval = true
  }
  opt.parse!(ARGV)

  unless ARGV.length == 2
    puts opt.help
    exit
  end

  file, cmd = ARGV
  unless File.exist?(file) or file == '-'
    raise CWLInspectionError, "No such file: #{file}"
  end

  fmt = if format == :yaml
          ->(a) { YAML.dump(a) }
        else
          ->(a) { JSON.dump(a) }
        end

  if inp_obj.nil? and do_eval
    raise CWLInspectionError, '--evaluate-expressions needs job file'
  end

  cwl = if file == '-'
          CommonWorkflowLanguage.load(YAML.load_stream(STDIN).first, Dir.pwd, {}) # TODO
        else
          CommonWorkflowLanguage.load_file(file, do_preprocess)
        end
  inputs = parse_inputs(cwl, inp_obj,
                        file == '-' ? Dir.pwd : File.dirname(File.expand_path file))
  runtime = eval_runtime(file, inputs, outdir, tmpdir)

  ret = case cmd
        when /^\..*/
          ret = walk(cwl, cmd)
          if do_eval
            ret = ret.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                               inputs, runtime)
          end
          fmt.call ret.to_h
        when /^keys\((\..*)\)$/
          fmt.call keys(cwl, $1)
        when 'commandline'
          case walk(cwl, '.class')
          when 'CommandLineTool'
            if runtime['cores'].nil?
              raise 'Specified minimum CPU cores is larger than the number of CPU cores'
            elsif runtime['ram'].nil?
              raise 'Specified minimum memory size is larger than the installed memory size'
            end
            commandline(cwl, runtime, inputs)
          when 'ExpressionTool'
            obj = cwl.expression.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                          inputs, runtime).to_h
            "echo '#{JSON.dump(obj).gsub("'"){ "\\'" }}' > #{File.join(runtime['outdir'], 'cwl.output.json')}"
          else
            raise CWLInspectionError, "`commandline` does not support #{walk(cwl, '.class')} class"
          end
        when 'list'
          case walk(cwl, '.class')
          when 'CommandLineTool', 'ExpressionTool'
            fmt.call list(cwl, runtime, inputs)
          else
            raise CWLInspectionError, "`list` does not support #{walk(cwl, '.class')} class"
          end
        else
          raise CWLInspectionError, "Unsupported command: #{cmd}"
        end
  puts ret
end
