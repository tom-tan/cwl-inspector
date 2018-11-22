#!/usr/bin/env ruby
# coding: utf-8

#
# Copyright (c) 2018 Tomoya Tanjo
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
require 'json'
require 'yaml'
require 'open-uri'
require 'optparse'

def preprocess(file)
  file = if file.match(/^(.+?)#.+$/)
           $1
         else
           file
         end
  obj = YAML.load_file(file)
  basedir = File.dirname(File.expand_path(file))
  traverse(obj, basedir)
end

def traverse(obj, basedir)
  case obj
  when Array
    obj.map{ |o|
      traverse(o, basedir)
    }
  when Hash
    if obj.include? '$import'
      import_resource(obj['$import'], basedir)
    elsif obj.include? '$include'
      include_resource(obj['$include'], basedir)
    elsif obj.include? '$mixin'
      removed = obj.dup
      mixin = removed.delete('$mixin')
      o = import_resource(mixin, basedir)
      o.merge(removed.transform_values{ |v|
                traverse(v, basedir)
              })
    else
      obj.transform_values{ |v|
        traverse(v, basedir)
      }
    end
  else
    obj
  end
end

def import_resource(uri, basedir)
  obj = case uri
        when %r|^https?://|
          YAML.load(open(uri, :open_timeout => 2))
        when %r|^file://(.+)$|
          YAML.load_file($1)
        when %r|^/|
          YAML.load_file(uri)
        else
          YAML.load_file(File.expand_path(uri, basedir))
        end
  traverse(obj, basedir)
end

def include_resource(uri, basedir)
  case uri
  when %r|^https?://|
    open(uri, :open_timeout => 2).read
  when %r|^file://(.+)$|
    open($1).read
  when %r|^/|
    open(uri).read
  else
    open(File.expand_path(uri, basedir)).read
  end
end

def fragments(obj)
  obj = preprocess(obj) if obj.instance_of? String
  collect_fragments(obj)
end

def collect_fragments(obj, acc = {})
  case obj
  when Array
    obj.map{ |o|
      collect_fragments(o, acc)
    }
  when Hash
    if obj.include?('name') and obj['name'].instance_of?(String)
      frag = if obj['name'].start_with? '#'
               obj['name'][1..-1]
             else
               obj['name']
             end
      acc[frag] = obj
    elsif obj.include?('id') and obj['id'].instance_of?(String)
      frag = if obj['id'].start_with? '#'
               obj['id'][1..-1]
             else
               obj['id']
             end
      acc[frag] = obj
    end
    obj.values.map{ |o|
      collect_fragments(o, acc)
    }
  end
  acc
end

def namespaces(obj)
  obj.fetch('$namespaces', {})
end

if $0 == __FILE__
  return_fragment = false
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} cwl"
  opt.on('--fragments', 'return fragments instead of preprocessed object') {
    return_fragment = true
  }
  opt.parse!(ARGV)

  unless ARGV.length == 1
    puts opt.help
    exit
  end

  cwl = ARGV.pop
  obj = if return_fragment
          fragments(preprocess(cwl))
        else
          preprocess(cwl)
        end
  puts JSON.dump(obj)
end
