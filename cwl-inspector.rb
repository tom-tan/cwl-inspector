#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'optparse'

def inspect_pos(cwl, pos)
  pos.split('.').reduce(cwl) { |cwl_, po|
    case po
    when 'inputs', 'outputs', 'steps' # TODO: consider `position`
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
      po = po.to_i if po.match(/\d+/)
      if cwl_.instance_of? Array
        raise "No such field #{pos}" unless po < cwl_.length
      elsif not cwl_.include? po # Hash
        raise "No such field #{pos}"
      end
      cwl_[po]
    end
  }
end

# TODO: more clean implementation
def cwl_fetch(cwl, pos)
  begin
    inspect_pos(cwl, pos)
  rescue
    nil
  end
end

def to_cmd(cwl)
  reqs = cwl_fetch(cwl, 'requirements')
  docker_idx = nil
  unless reqs.nil?
    docker_idx = reqs.find_index{ |e| e['class'] == 'DockerRequirement' }
  end

  [
    *unless docker_idx.nil?
      ["docker run --rm",
       inspect_pos(cwl, "requirements.#{docker_idx}.dockerPull")]
    else
      []
    end,
    *inspect_pos(cwl, 'baseCommand'),
    *inspect_pos(cwl, 'inputs').map { |id, param|
      to_input_param_args(cwl, id)
    }.flatten(1)
  ].join(' ')
end

def to_input_param_args(cwl, id)
  dat = inspect_pos(cwl, "inputs.#{id}")
  pre = dat.fetch('prefix', nil)
  args = if pre
           if dat.fetch('separate', false)
             [pre, "$#{id}"].join('')
           else
             [pre, "$#{id}"]
           end
         else
           ["$#{id}"]
         end
  if dat['type'].end_with?('?')
    ['[', *args, ']']
  else
    args
  end
end

def cwl_inspect(cwl, pos)
  cwl = YAML.load_file(cwl)
  # TODO: validate CWL
  if pos == 'commandline'
    if inspect_pos(cwl, 'class') == 'Workflow'
      raise "'commandline' can be used for CommandLineTool"
    end
    to_cmd(cwl)
  else
    inspect_pos(cwl, pos)
  end
end

if $0 == __FILE__
  printer = :puts
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} cwl pos"
  opt.on('--raw', 'print raw output') {
    printer = :p
  }
  opt.parse!(ARGV)

  unless ARGV.length == 2
    puts opt.banner
    exit
  end

  cwl, pos = ARGV
  Kernel.method(printer).call cwl_inspect(cwl, pos)
end