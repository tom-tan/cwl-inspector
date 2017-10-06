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

def to_cmd(cwl, args)
  [
    *docker_cmd(cwl),
    *cwl_fetch(cwl, '.baseCommand', []),
    *cwl_fetch(cwl, '.arguments', []).map{ |body|
      to_input_param_args(cwl, nil, body)
    }.flatten(1),
    *inspect_pos(cwl, '.inputs').map { |id, body|
      to_input_param_args(cwl, id, body, args)
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

def to_input_param_args(cwl, id, body, params={})
  return body if body.instance_of? String

  input = id.nil? ? nil : params.fetch(id, "$#{id}")
  param = if body.include? 'valueFrom'
            e = body['valueFrom'].match(/^\s*(.+)\s*$/m)[1]
            if e.start_with? '$'
              # it may use `input`
              eval_expression(cwl, e[1..-1])
            else
              e
            end
          else
            input
          end
  if param.instance_of? Array
    # TODO: Check the behavior if itemSeparator is missing
    param = param.join(body.fetch('itemSeparator', ' '))
  end

  pre = body.fetch('prefix', nil)
  argstrs = if pre
              if body.fetch('separate', false)
                [pre, param].join('')
              else
                [pre, param]
              end
            else
              [param]
            end
  if param == "$#{id}" and body.fetch('type', '').end_with?('?')
    ['[', *argstrs, ']']
  else
    argstrs
  end
end

def to_step_cmd(cwl, step, dir, args)
  step_ = inspect_pos(cwl, step)
  step_cmd = step_['run']
  step_args = Hash[step_['in'].map{ |k, v|
                     v = "[#{v}]" if v.include? '/'
                     if args.include? v
                       [k, args[v]]
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
  cwl_inspect(step_cwl, 'commandline', dir, step_args)
end

def cwl_inspect(cwl, pos, dir = nil, args = {})
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
    to_cmd(cwl, args)
  when /^commandline\((.+)\)$/
    unless inspect_pos(cwl, '.class') == 'Workflow'
      raise 'commandline for CommandLineTool does not need an argument'
    end
    to_step_cmd(cwl, $1, dir, args)
  else
    raise "Unknown pos: #{pos}"
  end
end

if $0 == __FILE__
  fmt = ->(a) { a }
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} cwl pos"
  opt.on('--yaml', 'print in YAML format') {
    fmt = ->(a) { YAML.dump(a) }
  }
  opt.on('--nodejs-bin=NODE', 'path to nodejs for InlineJavascriptRequirement') { |nodejs|
    $nodejs = nodejs
  }
  opt.parse!(ARGV)

  unless ARGV.length >= 2
    puts opt.help
    exit
  end

  cwlfile, pos, *args = ARGV
  args = to_arg_map(args.map{ |a| a.split('=') }.flatten)
  cwl = if cwlfile == '-'
          YAML.load_stream(STDIN)[0]
        else
          YAML.load_file(cwlfile)
        end
  puts fmt.call cwl_inspect(cwl, pos, File.dirname(cwlfile), args)
end
