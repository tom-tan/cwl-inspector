#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
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
          # raise if not CommandInputParameter
          raise "No such field #{pos}" unless cwl_.values.first.include? 'id'
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

def to_cmd(cwl)
  reqs = cwl_fetch(cwl, 'requirements', nil)
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
    *cwl_fetch(cwl, 'baseCommand', []),
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
