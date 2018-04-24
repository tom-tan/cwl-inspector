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

require 'etc'
require 'yaml'
require 'json'
require 'optparse'
require 'digest/sha1'

def cwl_file_find(file, settings)
  file = File.join(settings[:doc_dir], file)
  if File.exist? file
    return file
  end
  # TODO: Search other lookup paths
  nil
end

def inspect_pos(cwl, pos)
  pos[1..-1].split('.').reduce(cwl) { |cwl_, po|
    case po
    when 'inputs', 'outputs', 'steps'
      raise "No such field #{pos}" unless cwl_.include? po
      if cwl_[po].instance_of? Array
        Hash[cwl_[po].map{ |e| [e['id'], e] }]
      else
        cwl_[po]
      end
    when 'baseCommand'
      raise "No such field #{pos}" unless cwl_.include? po
      if cwl_[po].instance_of? String
        [cwl_[po]]
      else
        cwl_[po]
      end
    when 'requirements', 'hints'
      if cwl_[po].instance_of? Array
        Hash[cwl_[po].map{ |e| [e['class'], e] }]
      else
        cwl_[po]
      end
    when 'type'
      if cwl_[po].instance_of? Hash
        obj = cwl_[po]
        if obj.include? 'type' and obj.include? 'items'
          "#{obj['type']}[]"
        else
          obj
        end
      elsif cwl_[po].instance_of? Array
        obj = cwl_[po]
        if obj[0] == 'null'
          "#{obj[1]}?"
        else
          obj
        end
      else
        cwl_[po]
      end
    else
      if po.match(/^\d+$/)
        po = po.to_i
        if cwl_.instance_of? Array
          raise "No such field #{pos}" unless po < cwl_.length
          cwl_[po]
        else # Hash
          candidates = cwl_.values.find_all{ |e|
            e.fetch('inputBinding', { 'position' => 0 }).fetch('position', 0) == po
          }
          raise "No such field #{pos}" if candidates.empty?
          raise "Duplicated index #{po} in #{pos}" if candidates.length > 1
          candidates.first
        end
      else
        raise "No such field #{pos}" unless cwl_.include? po
        cwl_[po]
      end
    end
  }
end

def process(cwl, settings)
  inputs_args = cwl_fetch(cwl, '.inputs', []).with_index.map{ |i, e|
    id = nil ###
    val = settings[:args].fetch(id, e.fetch('default', nil))
    obj = e.fetch('inputBinding', nil)
    arg, idx = eval_input_object(obj, val)
    [[idx, i], arg]
  }
  args_args = cwl_f.tch(cwl, '.arguments', []).with_index.map{ |i, obj|
    arg, idx = eval_input_object(obj)
    [[idx, i], arg]
  }
  [*inputs_args, *args_args].sort_by{|a, b| a }.map{ |i, arg| arg }
end

def eval_input_object(obj, value=nil)
  return [] if obj.nil?

  value = if obj.include? 'valueFrom'
            exp = obj['valueFrom'].match(/^\s*(.+)\s*$/m)[1].chomp
            ### add treatment for loadContent
            instantiate_context(cwl, exp, settings)
          else
            value #
          end

  if value.instance_of? Hash
    value = case value.fetch('class', '')
            when 'File'
              value['path']
            else
              value
            end
  end

  if value.instance_of? Array
    # TODO: Check the behavior if itemSeparator is missing
    value = value.join(body.fetch('itemSeparator', ' '))
  end

  [*arg, obj.fetch('position', 0)]
end

# TODO: more clean implementation
def cwl_fetch(cwl, pos, default)
  begin
    inspect_pos(cwl, pos)
  rescue
    default
  end
end

def docker_cmd(cwl, settings)
  img = if cwl_fetch(cwl, '.requirements.DockerRequirement', nil)
          cwl_fetch(cwl, ".requirements.DockerRequirement.dockerPull", nil)
        elsif cwl_fetch(cwl, '.hints.DockerRequirement', nil) and system('which docker > /dev/null')
          cwl_fetch(cwl, '.hints.DockerRequirement.dockerPull', nil)
        else
          nil
        end
  if img
    docker_cmd = ['docker', 'run', '-i', '--rm', '--workdir=/private/var/spool/cwl', '--env=TMPDIR=/tmp', '--env=HOME=/private/var/spool/cwl']
    volume_map = {}
    cwl_fetch(cwl, '.inputs', []).dup.keep_if{ |k, v|
      v.instance_of?(Hash) and (cwl_fetch(v, '.type', '').start_with?('File') or cwl_fetch(v, '.type', '').start_with?('Directory'))
    }.keep_if{ |k, v|
      settings[:args].include?(k) or v.include?('default')
    }.each{ |k, v|
      obj = v.fetch('default', settings[:args][k])
      path = obj.fetch('path', obj.fetch('location', nil))
      docker_path = "/private/var/lib/cwl/inputs/#{File.basename(path)}"
      docker_cmd.push("-v #{path}:#{docker_path}:ro")
      volume_map[k] = docker_path
    }

    cwl_fetch(cwl, '.outputs', []).dup.keep_if{ |k, v|
      type = inspect_pos(v, '.type')
      type.start_with?('File') or type.start_with?('Directory')
    }.each{ |k, v|
      docker_path = "/private/var/lib/cwl/outputs"
      docker_cmd.push("-v #{settings[:runtime]['outdir']}:#{docker_path}:rw")
      volume_map[k] = docker_path
    }
    docker_cmd.push(img)
    [docker_cmd, volume_map]
  else
    [[], {}]
  end
end

def construct_args(cwl, vol_map, settings)
  arr = cwl_fetch(cwl, '.arguments', []).to_enum.with_index.map{ |body, idx|
    i = if body.instance_of? String
          0
        else
          body.fetch('position', 0)
        end
    [[i, idx], to_input_param_args(cwl, nil, body, settings, vol_map)]
  }+cwl_fetch(cwl, '.inputs', []).find_all{ |id, body|
      body.include? 'inputBinding'
  }.to_enum.with_index.map { |id_body, idx|
    i = id_body[1]['inputBinding'].fetch('position', 0)
    [[i, id_body[0]], id_body[0], id_body[1]]
  }.map{ |idx, id, body|
    [idx, to_input_param_args(cwl, id, body, settings, vol_map)]
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

def to_cmd(cwl, settings)
  docker_cmd, vol_map = docker_cmd(cwl, settings)
  [
    *docker_cmd,
    *cwl_fetch(cwl, '.baseCommand', []),
    *construct_args(cwl, vol_map, settings),
    *if cwl_fetch(cwl, '.stdout', nil) or
      not cwl_fetch(cwl, '.outputs', []).find_all{ |k, v| v.fetch('type', '') == 'stdout' }.empty?
      fname = cwl_fetch(cwl, '.stdout', '$randomized_filename')
      fname = instantiate_context(cwl, fname, settings)
      ['>', File.join(settings[:runtime]['outdir'], fname)]
    else
      []
    end
  ].join(' ')
end

def to_arg_map(args)
  raise "Invalid arguments: #{args}" if args.length.odd?
  Hash[
    0.step(args.length-1, 2).map{ |i|
      opt = args[i][2..-1]
      [opt, args[i+1]]
    }]
end

def node_bin
  if $nodejs
    raise "#{$nodejs} is not executable or does not exist" unless File.executable? $nodejs
    $nodejs
  else
    node = ['node', 'nodejs'].find{ |n|
      system("which #{n} > /dev/null")
    }
    raise "No executables for Nodejs" if node.nil?
    node
  end
end

def exec_node(fun)
  node = node_bin
  cmdstr = <<-EOS
  'use strict'
  try{
    process.stdout.write(JSON.stringify((#{fun})()))
  } catch(e) {
    process.stdout.write(JSON.stringify(`${e.name}: ${e.message}`))
  }
EOS
  ret = JSON.load(IO.popen([node, '--eval', cmdstr]) { |io| io.gets })
  raise ret if ret.instance_of? String and ret.match(/^.+Error: .+$/)
  ret
end

def eval_expression(cwl, exp, settings)
  if cwl_fetch(cwl, '.requirements.InlineJavascriptRequirement', nil)
    ret = exp.start_with?('{') ? "(function() #{exp})()" : exp[1..-2]
    fbody = <<EOS
function() {
  const runtime = #{JSON.dump(settings[:runtime])};
  const inputs = #{JSON.dump(init_inputs_context(cwl, settings[:args]))};
  const self = null;
  return #{ret};
}
EOS
    exec_node(fbody)
  else
    fields = exp[1..-2].split('.')
    context = case fields.first
              when 'runtime'
                settings[:runtime]
              when 'inputs'
                init_inputs_context(cwl, settings[:args])
              when 'self'
              else
                raise "Invalid context: #{fields}"
              end
    fields[1..-1].reduce(context){ |con, f|
      if con.include? f
        con.fetch(f, exp)
      else
        break "$#{exp[1..-2]}"
      end
    }
  end
end

def extract_path(path, basedir)
  if path.nil?
    nil
  elsif path.match %r|^file://(.+)$|
    $1
  elsif path.start_with? '/'
    path
  else
    File.expand_path(path, basedir)
  end
end

def to_input_param_args(cwl, id, body, settings, volume_map)
  return instantiate_context(cwl, body, settings) if body.instance_of? String

  value = if body.include? 'valueFrom'
            str = body['valueFrom'].match(/^\s*(.+)\s*$/m)[1].chomp
            instantiate_context(cwl, str, settings)
          elsif body.include? 'default'
            default = body.fetch('default')
            if default.instance_of? Hash
              case default.fetch('class', '')
              when 'File', 'Directory'
                default.fetch('path', extract_path(default.fetch('location', nil),
                                                   settings[:doc_dir]))
              else
                default
              end
            else
              default
            end
          else
            id.nil? ? nil : settings[:args].fetch(id, "$#{id}")
          end

  if value.instance_of? Hash
    value = case value.fetch('class', '')
            when 'File', 'Directory'
              volume_map.fetch(id, value.fetch('path',
                                               extract_path(value.fetch('location', nil),
                                                            settings[:doc_dir])))
            else
              value
            end
  elsif value.instance_of? Array
    value = value.map{ |v|
      if v.instance_of? Hash
        case v.fetch('class', '')
        when 'File', 'Directory'
          volume_map.fetch(id, v.fetch('path',
                                       extract_path(v.fetch('location', nil),
                                                    settings[:doc_dir])))
        else
          v
        end
      else
        v
      end
    }
  end

  if value.instance_of? Array
    # TODO: Check the behavior if itemSeparator is missing
    value = value.map{|v| "'#{v}'" } if body.fetch('shellQuote', true) and value.first.instance_of? String
    value = value.join(body.fetch('inputBinding', {}).fetch('itemSeparator', ' '))
  else
    type = cwl_fetch(body, '.type', '')
    if type.instance_of? String
      if type.start_with?('string') and body.fetch('shellQuote', true)
        value = "'#{value}'"
      elsif type.start_with?('File')
        value = "'#{value}'"
      end
    elsif type.instance_of?(NilClass) and value.instance_of?(String) and
         body.fetch('shellQuote', true)
      value = "'#{value}'"
    end
  end

  pre = (body.fetch('prefix', nil) or body.fetch('inputBinding', {}).fetch('prefix', nil))

  argstrs = if pre
              if body.fetch('separate', false)
                [pre, value].join('')
              else
                type = body.fetch('type', '')
                if type.instance_of? String and body.fetch('type', '').start_with? 'boolean'
                  value ? [pre] : []
                else
                  [pre, value]
                end
              end
            else
              [value]
            end
  if value.instance_of?(String) and value.match(/^'\$#{id}'$/) and
    cwl_fetch(body, '.type', '').end_with?('?')
    if settings[:args].empty?
      ['[', *argstrs, ']']
    else
      argstrs
    end
  else
    argstrs
  end
end

def init_inputs_context(cwl, args)
  ret = cwl_fetch(cwl, '.inputs', {}).select{ |k, v| args.include? k }.map{ |k, v|
    case v.fetch('type', nil)
    when 'File'
      # inputs.*
      # inputs.*.location
      file = args[k]
      hash = {
        'class' => 'File',
        'path' => File.absolute_path(file),
        'basename' => File.basename(file),
        'dirname' => File.dirname(file),
        'nameroot' => File.basename(file).sub(File.extname(file), ''),
        'nameext' => File.extname(file),
      }

      if v.include? 'format'
        hash['format'] = v['format']
      end

      if File.exist? file
        digest = Digest::SHA1.hexdigest(File.open(file, 'rb').read)
        hash['checksum'] = "sha1$#{digest}"
        hash['size'] = File.size(file)
        hash['contents'] = File.open(file) { |io|
          io.read(64*2**10)
        }
      end
      [k, hash]
    when 'Directory'
      dir = args[k]
      hash = {
        'class' => 'Drectory',
        'path' => File.absolute_path(dir),
        'basename' => File.basename(dir),
      }
      if Dir.exist? dir
        hash['listing'] = Dir.entries(dir).select{ |e| not e.match(/^\.+$/) }
      end
    else
      [k, v]
    end
  }.flatten(1)
  Hash[*ret]
end

def init_self_context(cwl, args)
  {}
end

def instantiate_context(cwl, str, settings)
  if str.match(/\$(\(.+\))/m) or str.match(/\$(\{.+\})/m)
    # current assumption: Expression is included at most once
    # TODO: extend it to satisfy the spec
    pre, post = $~.pre_match, $~.post_match
    begin
      exp, evaled = $~[0], eval_expression(cwl, $1, settings)
      if pre.empty? and post.empty?
        evaled
      else
        str.sub(exp, evaled)
      end
    rescue => e
      if e.to_s.match(/^.+Error/)
        str
      else
        raise e
      end
    end
  else
    str
  end
end

def ls_outputs_for_cmd(cwl, id, settings)
  unless cwl_fetch(cwl, id, false)
    raise "Invalid pos #{id}"
  end
  dir = settings[:runtime]['outdir']
  type = cwl_fetch(cwl, "#{id}.type", '')
  if File.exist? File.join(dir, 'cwl.output.json')
    id_ = id.split('.').last
    outputs = open(File.join(dir, 'cwl.output.json')) { |f|
      JSON.load(f)
    }
    if outputs.include? id_
      outputs[id_]
    elsif type.end_with? '?'
      nil
    else
      raise "#{id_} should exist in cwl.output.json but does not"
    end
  elsif type == 'stdout'
    fname = cwl_fetch(cwl, ".stdout", '$randomized_filename')
    fname = instantiate_context(cwl, fname, settings)
    {
      'class' => 'File',
      'path' => File.absolute_path(dir.nil? ? fname : File.join(dir, fname)),
    }
  else
    oBinding = cwl_fetch(cwl, "#{id}.outputBinding", nil)
    if oBinding.nil?
      raise "Not yet supported for outputs without outputBinding"
    end
    if oBinding.include? 'glob'
      pat = instantiate_context(cwl, oBinding['glob'], settings)
      if pat.include? '*' or pat.include? '?' or pat.include? '['
        ret = Dir.glob(dir.nil? ? pat : File.join(dir, pat))
        if type == 'File'
          {
            'class' => 'File',
            'path' => File.absolute_path(ret.first),
          }
        elsif type == 'File[]' or
              { 'type' => 'array', 'items' => 'File' }
          ret.map{ |it|
            {
              'class' => 'File',
              'path' => File.absolute_path(it),
            }
          }
        end
      else
        {
          'class' => 'File',
          'path' => File.absolute_path(pat),
        }
      end
    end
  end
end

def to_step_cmd(cwl, step, settings)
  step_ = inspect_pos(cwl, step)
  step_cmd = step_['run']
  step_args = Hash[step_['in'].map{ |k, v|
                     v = "[#{v}]" if v.include? '/'
                     if settings[:args].include? v
                       [k, settings[:args][v]]
                     else
                       [k, "$#{v}"]
                     end
                   }]
  case step_cmd
  when String
    step_cwl_file = cwl_file_find(step_cmd, settings)
    raise "File not found: #{step_cmd} defind in step #{step}" if step_cwl_file.nil?
    step_cwl = YAML.load_file(step_cwl_file)
  else
    step_cwl = step_cmd
  end
  # TODO: How to handle workflows and expressions for 'commandline'?
  cwl_inspect(step_cwl, 'commandline',
              { :runtime => settings[:runtime], :args => step_args,
                :doc_dir => File.absolute_path(step_cwl_file) })
end

def cwl_inspect(cwl, pos, settings = { :runtime => {}, :args => {}, :doc_dir => nil })
  # TODO: validate CWL
  case pos
  when /^\./
    inspect_pos(cwl, pos)
  when /^keys\((.+)\)$/
    inspect_pos(cwl, $1).keys
  when /^commandline$/
    unless inspect_pos(cwl, '.class') == 'CommandLineTool'
      raise 'commandline for Workflow needs an argument'
    end
    to_cmd(cwl, settings)
  when /^commandline\((.+)\)$/
    unless inspect_pos(cwl, '.class') == 'Workflow'
      raise 'commandline for CommandLineTool does not need an argument'
    end
    to_step_cmd(cwl, $1, settings)
  when /^list-outputs$/
    class_ = inspect_pos(cwl, '.class')
    case class_
    when 'Workflow'
      raise "list-outputs is not supported for workflows"
    when 'CommandLineTool'
      Hash[inspect_pos(cwl, '.outputs').keys.map{ |k|
             [k,
              ls_outputs_for_cmd(cwl, ".outputs.#{k}", settings)
             ]
           }]
    else
      raise "Unsupported class: #{class_}"
    end
  when /^ls\((\.outputs\..+)\)$/
    # TODO: Is .steps.foo enough?
    # How about .steps.foo.out1?
    case inspect_pos(cwl, '.class')
    when 'Workflow'
      raise "Not yet implemented it for Workflow"
    when 'CommandLineTool'
      ret = ls_outputs_for_cmd(cwl, $1, settings)
      if settings[:runtime]['output-in-cwltype']
        ret.nil? ? 'null' : ret
      else
        if ret.instance_of? Array
          ret.map{ |it|
            if it.instance_of? Hash
              case it.fetch('class', '')
              when 'File', 'Directory'
                it['path']
              else
                it
              end
            else
              it
            end
          }
        elsif ret.instance_of? Hash
          case it.fetch('class', '')
          when 'File', 'Directory'
            ret['path']
          else
            ret
          end
        else
          ret
        end
      end
    else
      raise "Unsupported class #{inspect_pos(cwl, '.class')}"
    end
  when /^ls\((\.steps\..+)\)$/
    unless inspect_pos(cwl, '.class') == 'Workflow'
      raise "ls outputs for steps does not work for CommandLineTool"
    end
    raise "Not yet implemented"
  else
    raise "Unknown pos: #{pos}"
  end
end

def trans_args(args, cwl, ret = {})
  return ret if args.empty?

  arg = args.shift
  raise "Error" unless arg.start_with? '--'
  neg, arg = arg.match(/^--(no-)?(.+)$/).values_at(1, 2)
  type = cwl_fetch(cwl, ".inputs.#{arg}.type", nil)
  raise "No such argment: #{arg}" if type.nil?

  base, suffix = type.match(/^(.+)(\[\])?(\?)?$/).values_at(0, 1)
  val = case base
        when 'boolean'
          neg.nil? ? true : false
        when 'File', 'Directory'
          raise "--no prefix is only valid for boolean types" unless neg.nil?
          {
            'class' => base,
            'path' => args.shift,
          }
        else
          raise "--no prefix is only valid for boolean types" unless neg.nil?
          args.shift
        end

  if suffix == '[]'
    ret.fetch(arg, []).push(val)
  else
    ret[arg] = val
  end

  trans_args(args, cwl, ret)
end

def get_runtime_cores(cwl)
  reqs = cwl_fetch(cwl, '.requirements.ResourceRequirement', {})
  hints = cwl_fetch(cwl, '.hints.ResourceRequirement', {})
  min = reqs.fetch('coresMin', hints.fetch('coresMin', nil))
  max = reqs.fetch('coresMax', hints.fetch('coresMax', nil))

  raise "Invalid ResourceRequirement" if not min.nil? and not max.nil? and max < min
  min = max if min.nil?
  max = min if max.nil?
  ncores = Etc.nprocessors
  if min.nil? and max.nil?
    ncores
  else
    raise "Invalid ResourceRequirement" if ncores < min
    [ncores, max].min
  end
end

def get_runtime_ram(cwl)
  reqs = cwl_fetch(cwl, '.requirements.ResourceRequirement', {})
  hints = cwl_fetch(cwl, '.hints.ResourceRequirement', {})
  min = reqs.fetch('ramMin', hints.fetch('ramMin', nil))
  max = reqs.fetch('ramMax', hints.fetch('ramMax', nil))

  raise "Invalid ResourceRequirement" if not min.nil? and not max.nil? and max < min
  min = max if min.nil?
  max = min if max.nil?
  ram = 1024 # default value in cwltool
  if min.nil? and max.nil?
    ram
  else
    raise "Invalid ResourceRequirement" if ram < min
    [ram, max].min
  end
end

if $0 == __FILE__
  fmt = ->(a) { a }
  runtime = Hash.new(nil)
  runtime['outdir'] = File.absolute_path(Dir.pwd)
  runtime['output-in-cwltype'] = false

  input = nil
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} cwl pos"
  opt.on('--yaml', 'print in YAML format') {
    fmt = ->(a) { YAML.dump(a) }
  }
  opt.on('--json', 'print in JSON format') {
    fmt = ->(a) { JSON.dump(a) }
  }
  opt.on('--nodejs-bin=NODE', 'path to nodejs for InlineJavascriptRequirement') { |nodejs|
    $nodejs = nodejs
  }
  opt.on('--outdir=DIR', 'directory for outputs') { |dir|
    runtime['outdir'] = File.absolute_path(dir)
  }
  opt.on('--tmpdir=DIR', 'directory for temporary files') { |dir|
    runtime['tmpdir'] = File.absolute_path(dir)
  }
  opt.on('-i YML', 'input parameters') { |yml|
    input = yml
  }
  opt.on('--cwl-type', 'Print output object as a CWL object') {
    runtime['output-in-cwltype'] = true
  }
  opt.parse!(ARGV)

  unless ARGV.length >= 2
    puts opt.help
    exit
  end

  cwlfile, pos, *args = ARGV

  args = if not(input.nil?) and not(args.empty?)
           raise "Error: -i yml and -- --param1 p1 are exclusive"
         elsif not input.nil?
           YAML.load_file(input)
         elsif not args.empty?
           args.map{ |a| a.split(/=/) }.flatten
         else
           Hash.new(nil)
         end

  cwl = if cwlfile == '-'
          YAML.load_stream(STDIN)[0]
        else
          YAML.load_file(cwlfile)
        end

  runtime['cores'] = get_runtime_cores(cwl)
  runtime['ram'] = get_runtime_ram(cwl)

  settings = {
    :runtime => runtime,
    :args => (args.instance_of?(Array) ? trans_args(args, cwl) : args),
    :doc_dir => File.expand_path(File.dirname(cwlfile)),
  }
  puts fmt.call cwl_inspect(cwl, pos, settings)
end
