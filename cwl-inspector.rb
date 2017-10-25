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

require 'yaml'
require 'json'
require 'optparse'
require 'digest/sha1'

def cwl_file_find(file, dir)
  if File.exist? File.join(dir, file)
    return File.join(dir, file)
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
    else
      if po.match(/\d+/)
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

# TODO: more clean implementation
def cwl_fetch(cwl, pos, default)
  begin
    inspect_pos(cwl, pos)
  rescue
    default
  end
end

def docker_cmd(cwl)
  img = if cwl_fetch(cwl, '.requirements', []).find_index{ |e| e['class'] == 'DockerRequirement' }
          idx = cwl_fetch(cwl, '.requirements', []).find_index{ |e|
            e['class'] == 'DockerRequirement'
          }
          inspect_pos(cwl, ".requirements.#{idx}.dockerPull")
        elsif cwl_fetch(cwl, '.hints.DockerRequirement', nil) and system('which docker > /dev/null')
          cwl_fetch(cwl, '.hints.DockerRequirement.dockerPull', nil)
        else
          nil
        end
  if img
    ['docker', 'run', '-i', '--rm', img]
  else
    []
  end
end

def to_cmd(cwl, settings)
  [
    *docker_cmd(cwl),
    *cwl_fetch(cwl, '.baseCommand', []),
    *cwl_fetch(cwl, '.arguments', []).map{ |body|
      to_input_param_args(cwl, nil, body, settings)
    }.flatten(1),
    *cwl_fetch(cwl, '.inputs', []).find_all{ |id, body|
      body.include? 'inputBinding'
    }.each_with_index.sort_by{ |id_body, idx|
      [id_body[1]['inputBinding'].fetch('position', 0), idx]
    }.map{ |id_body, idx|
      id_body
    }.map { |id, body|
      to_input_param_args(cwl, id, body, settings)
    }.flatten(1)
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

def exec_node(cmd)
  node = node_bin
  cmdstr = <<-EOS
  try{
    process.stdout.write(JSON.stringify((function() #{cmd})()))
  } catch(e) {
    process.stdout.write(JSON.stringify(`${e.name}: ${e.message}`))
  }
EOS
  ret = JSON.load(IO.popen([node, '--eval', cmdstr]) { |io| io.gets })
  raise ret if ret.instance_of? String and ret.match(/^.+Error: .+$/)
  ret
end

def eval_expression(cwl, exp)
  if cwl_fetch(cwl, '.requirements', []).find_index{ |it| it['class'] == 'InlineJavascriptRequirement' }
    fbody = exp.start_with?('(') ? "{ return #{exp}; }" : exp
    exec_node(fbody)
  else
    # inputs
    # runtime
    # runtime.outdir
    # self
    exp
  end
end

def to_input_param_args(cwl, id, body, settings)
  return instantiate_context(cwl, body, settings) if body.instance_of? String

  value = if body.include? 'valueFrom'
            e = body['valueFrom'].match(/^\s*(.+)\s*$/m)[1]
            if e.start_with? '$'
              # it may use `input`
              e = instantiate_context(cwl, e, settings)
              eval_expression(cwl, e[1..-1])
            else
              e
            end
          else
            id.nil? ? nil : settings[:args].fetch(id, "$#{id}")
          end

  if value.instance_of? Array
    # TODO: Check the behavior if itemSeparator is missing
    value = value.join(body.fetch('itemSeparator', ' '))
  end

  pre = body.fetch('prefix', nil)
  argstrs = if pre
              if body.fetch('separate', false)
                [pre, value].join('')
              else
                [pre, value]
              end
            else
              [value]
            end
  if value == "$#{id}" and body.fetch('type', '').end_with?('?')
    ['[', *argstrs, ']']
  else
    argstrs
  end
end

def init_inputs_context(cwl, args)
  context = Hash.new
  add_val = ->(key, field, &exp) {
    k = if field.nil?
          "$(inputs.#{key})"
        else
          "$(inputs.#{key}.#{field})"
        end
    context[k] = if args.include? key
                   exp.call key
                 else
                   k
                 end
  }
  cwl_fetch(cwl, '.inputs', {}).each{ |key, v|
    add_val.call(key, nil) { |k| args[k] }
    # add_val.call(key, 'location') { raise 'Not implemented' }
    add_val.call(key, 'path') { |k| File.absolute_path(args[k]) }
    add_val.call(key, 'basename') { |k| File.basename(args[k]) }
    add_val.call(key, 'dirname') { |k| File.dirname(args[k]) }
    add_val.call(key, 'nameroot') { |k|
      ext = File.extname(args[k])
      File.basename(settings[k]).sub(/#{ext}$/, '')
    }
    add_val.call(key, 'nameext') { |k| File.extname(args[k]) }
    add_val.call(key, 'checksum') { |k|
      file = args[k]
      if File.exist? file
        digest = Digest::SHA1.hexdigest(File.open(file, 'rb').read)
        "sha1$#{digest}"
      else
        "$(inputs.#{k}.checksum)"
      end
    }
    add_val.call(key, 'size') { |k|
      file = args[k]
      if File.exist? file
        File.size(file)
      else
        "$(inputs.#{k}.size)"
      end
    }
    # add_val.call(key, 'format') { raise 'Not implemented' }
    add_val.call(key, 'contents') { |k|
      file = args[k]
      if File.exist? file
        File.open(file) { |io|
          io.read(64*2**10)
        }
      else
        "$(inputs.#{k}.contents)"
      end
    }
  }
  context
end

def init_self_context(cwl, args)
  {}
end

def init_runtime_context(runtime)
  context = Hash.new
  runtime_map = {
    '$(runtime.outdir)' => 'outdir',
    '$(runtime.tmpdir)' => 'tmpdir',
    '$(runtime.cores)' => 'cores',
    '$(runtime.ram)' => 'ram',
    '$(runtime.outdirSize)' => 'outdirSize',
    '$(runtime.tmpdirSize)' => 'tmpdirSize',
  }
  runtime_map.each{ |k, v|
    context[k] = runtime.fetch(v, k)
  }
  context
end

def instantiate_context(cwl, pat, settings)
  ret = init_runtime_context(settings[:runtime]).reduce(pat) { |r, kv|
    r.gsub(*kv)
  }

  ret = init_inputs_context(cwl, settings[:args]).reduce(ret) { |r, kv|
    r.gsub(*kv)
  }

  init_self_context(cwl, settings).reduce(ret) { |r, kv|
    r.gsub(*kv)
  }
end

def ls_outputs_for_cmd(cwl, id, settings)
  unless cwl_fetch(cwl, id, false)
    raise "Invalid pos #{id}"
  end
  oBinding = cwl_fetch(cwl, "#{id}.outputBinding", nil)
  if oBinding.nil?
    raise "Not yet supported for outputs without outputBinding"
  end
  if oBinding.include? 'glob'
    pat = oBinding['glob']
    if pat.match(/\$\(.+\)/)
      pat = instantiate_context(cwl, pat, settings)
    end
    if pat.include? '*' or pat.include? '?' or pat.include? '['
      Dir.glob($runtime.fetch('outdir', '')+'/'+pat)
    else
      pat
    end
  end
end

def ls_outputs_for_workflow(cwl, id, dir, settings)
  if cwl_fetch(cwl, id, false)
    raise "Invalid pos #{id}"
  end
end

def to_step_cmd(cwl, step, dir, settings)
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
    step_cwl_file = cwl_file_find(step_cmd, dir)
    raise "File not found: #{step_cmd} defind in step #{step}" if step_cwl_file.nil?
    step_cwl = YAML.load_file(step_cwl_file)
  else
    step_cwl = step_cmd
  end
  # TODO: How to handle workflows and expressions for 'commandline'?
  cwl_inspect(step_cwl, 'commandline', dir,
              { :runtime => settings[:runtime], :args => step_args })
end

def cwl_inspect(cwl, pos, dir = nil, settings = { :runtime => {}, :args => {} })
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
    to_step_cmd(cwl, $1, dir, settings)
  when /^ls\((\.outputs\..+)\)$/
    # TODO: Is .steps.foo enough?
    # How about .steps.foo.out1?
    case inspect_pos(cwl, '.class')
    when 'Workflow'
      raise "Not yet implemented it for Workflow"
      ls_outputs_for_workflow(cwl, $1, dir, settings)
    when 'CommandLineTool'
      ls_outputs_for_cmd(cwl, $1, settings)
    else
      raise "Unsupported class #{inspect_pos(cwl, '.class')}"
    end
  when /^ls\((\.steps\..+)\)$/
    unless inspect_pos(cwl, '.class') == 'Workflow'
      raise "ls outputs for steps does not work for CommandLineTool"
    end
    raise "Not yet implemented"
    ls_outputs_for_workflow(cwl, $1, dir, settings)
  else
    raise "Unknown pos: #{pos}"
  end
end

if $0 == __FILE__
  fmt = ->(a) { a }
  runtime = Hash.new(nil)
  input = nil
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} cwl pos"
  opt.on('--yaml', 'print in YAML format') {
    fmt = ->(a) { YAML.dump(a) }
  }
  opt.on('--nodejs-bin=NODE', 'path to nodejs for InlineJavascriptRequirement') { |nodejs|
    $nodejs = nodejs
  }
  opt.on('--runtime.outdir=DIR', 'directory for outputs') { |dir|
    runtime['outdir'] = dir
  }
  opt.on('--runtime.tmpdir=DIR', 'directory for temporary files') { |dir|
    runtime['tmpdir'] = dir
  }
  opt.on('-i YML', 'input parameters') { |yml|
    input = yml
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
           YAML.load_file(inputs)
         elsif not args.empty?
           to_arg_map(args.map{ |a| a.split('=') }.flatten)
         else
           Hash.new(nil)
         end

  cwl = if cwlfile == '-'
          YAML.load_stream(STDIN)[0]
        else
          YAML.load_file(cwlfile)
        end

  settings = {
    :runtime => runtime,
    :args => args,
  }
  puts fmt.call cwl_inspect(cwl, pos, File.dirname(cwlfile), settings)
end
