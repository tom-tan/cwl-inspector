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

def inspect_pos(cwl, pos)
  pos.split('.').reduce(cwl) { |cwl_, po|
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

def to_cmd(cwl, args)
  args = to_arg_map(args)
  reqs = cwl_fetch(cwl, 'requirements', [])
  docker_idx = reqs.find_index{ |e| e['class'] == 'DockerRequirement' }

  [
    *unless docker_idx.nil?
      ["docker run -i --rm",
       inspect_pos(cwl, "requirements.#{docker_idx}.dockerPull")]
    else
      []
    end,
    *cwl_fetch(cwl, 'baseCommand', []),
    *cwl_fetch(cwl, 'arguments', []).map{ |a|
      to_input_arg(cwl, a)
    }.flatten(1),
    *inspect_pos(cwl, 'inputs').map { |id, param|
      to_input_param_args(cwl, id, args)
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
  JSON.load(IO.popen([node, '--eval',
                      "process.stdout.write(JSON.stringify((function() #{cmd})()))"]) { |io|
              ret = io.gets
              io.close_write
              ret
            })
end

def eval_expression(exp)
  # inputs
  # self
  # runtime
  exec_node(exp)
end

def to_input_arg(cwl, arg)
  if arg.instance_of? String
    arg
  else # Hash
    exp = arg['valueFrom'].match(/^\s*(.+)\s*$/m)[1]
    exp = if exp.start_with?('$')
            e = exp[1..-1]
            fbody = e.start_with?('(') ? "{ return #{e}; }" : e
            if cwl_fetch(cwl, 'requirements', []).find_index{ |it| it['class'] == 'InlineJavascriptRequirement' }
              eval_expression(fbody)
            else
              raise "Unimplemented Error"
            end
          else
            exp
          end

    if exp.instance_of? Array
      # TODO: Check the behavior if itemSeparator is missing
      exp = exp.join(arg.fetch('itemSeparator', ' '))
    end

    pre = arg.fetch('prefix', nil)
    if pre
      if arg.fetch('separate', false)
        [pre, exp].join('')
      else
        [pre, exp]
      end
    else
      [exp]
    end
  end
end

def to_input_param_args(cwl, id, args)
  param = args.fetch(id, "$#{id}")
  dat = inspect_pos(cwl, "inputs.#{id}")
  pre = dat.fetch('prefix', nil)
  args = if pre
           if dat.fetch('separate', false)
             [pre, param].join('')
           else
             [pre, param]
           end
         else
           [param]
         end
  if param == "$#{id}" and dat.fetch('type', '').end_with?('?')
    ['[', *args, ']']
  else
    args
  end
end

def cwl_inspect(cwl, pos, args = [])
  cwl = if cwl == '-'
          YAML.load_stream(STDIN)[0]
        else
          YAML.load_file(cwl)
        end
  # TODO: validate CWL
  if pos == 'commandline'
    if inspect_pos(cwl, 'class') == 'Workflow'
      raise "'commandline' can be used for CommandLineTool"
    end
    to_cmd(cwl, args)
  elsif pos.start_with? '.'
    unless args.empty?
      raise "Invalid arguments: #{args}"
    end
    inspect_pos(cwl, pos[1..-1])
  elsif pos.match(/^(.+)\(\.(.+)?\)$/)
    op, pos_ = $1, $2
    case op
    when 'keys'
      inspect_pos(cwl, pos_.nil? ? '' : pos_).keys
    else
      raise "Unknown operator: #{op}"
    end
  else
    raise "Error: pos should be .x.y.z, keys(.x.y.z) or 'commandline'"
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

  cwl, pos, *args = ARGV
  puts fmt.call cwl_inspect(cwl, pos, args)
end
