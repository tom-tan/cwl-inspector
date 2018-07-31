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
require 'fileutils'
require 'optparse'
require 'open-uri'
require 'securerandom'
require 'tmpdir'
require 'tempfile'
require 'digest/sha1'
require_relative 'exp-parser'
require_relative 'js-parser'

class CWLParseError < Exception
end

class CWLInspectionError < Exception
end

def walk(cwl, path, default=nil, exception=false)
  unless path.start_with? '.'
    raise CWLInspectionError, "Invalid path: #{path}"
  end
  if cwl.instance_of? String
    cwl = CommonWorkflowLanguage.load_file(cwl)
  end

  begin
    cwl.walk(path[1..-1].split(/\.|\[|\]\.|\]/))
  rescue CWLInspectionError => e
    if exception
      raise e
    else
      default
    end
  end
end

class NilClass
  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end
end

class Integer
  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end

  def to_h
    self
  end
end

class String
  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end

  def to_h
    self
  end
end

class TrueClass
  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end

  def to_h
    self
  end
end

class FalseClass
  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end

  def to_h
    self
  end
end

class Array
  def walk(path)
    if path.empty?
      return self
    end
    idx = path.shift
    if idx.match(/^\d+$/)
      i = idx.to_i
      if i >= self.length
        raise CWLInspectionError, "Invalid index for #{self.first.class}[]: #{i}"
      end
      self[idx.to_i].walk(path)
    else
      fst = self.first
      field = if fst.instance_variable_defined? '@id'
                '@id'
              elsif fst.instance_variable_defined? '@class_'
                '@class_'
              elsif fst.instance_variable_defined? '@package'
                '@package'
              else
                raise CWLInspectionError, "No such field: #{idx}"
              end
      i = self.index{ |e|
        e.instance_variable_get(field) == idx
      }
      if i.nil?
        raise CWLInspectionError, "No such field: #{idx}"
      end
      self[i].walk(path)
    end
  end

  def keys
    fst = self.first
    field = if fst.instance_variable_defined? '@id'
              '@id'
            elsif fst.instance_variable_defined? '@class_'
              '@class_'
            elsif fst.instance_variable_defined? '@package'
              '@package'
            else
              raise CWLInspectionError, "Invalid operation `keys` for #{self.first.class}[]"
            end
    self.map{ |e|
      e.instance_variable_get(field)
    }
  end

  def to_h
    self.map{ |e|
      e.to_h
    }
  end
end

class CommonWorkflowLanguage
  def self.load_file(file)
    obj = YAML.load_file(file)
    self.load(obj)
  end

  def self.load(obj)
    case obj.fetch('class', '')
    when 'CommandLineTool'
      CommandLineTool.load(obj)
    when 'Workflow'
      Workflow.load(obj)
    when 'ExpressionTool'
      ExpressionTool.load(obj)
    else
      raise CWLParseError, 'Cannot parse as #{self}'
    end
  end
end

class CWLObject
  def self.inherited(subclass)
    subclass.class_eval{
      def subclass.cwl_object_preamble(*fields)
        class_variable_set(:@@fields, fields)
        attr_reader(*fields)
      end

      def subclass.valid?(obj)
        obj.keys.all?{ |k|
          # TODO: check namespaces
          class_variable_get(:@@fields).map{ |m|
            m == :class_ ? :class : m
          }.any?{ |f|
            f.to_s == k
          }
        } and satisfies_additional_constraints(obj)
      end
    }
  end

  def self.satisfies_additional_constraints(obj)
    true
  end

  def walk(path)
    if path.empty?
      return self
    end
    field = path.shift
    f = field == 'class' ? '@class_' : "@#{field}"
    unless instance_variable_defined? f
      raise CWLInspectionError, "No such field for #{self.class}: #{field}"
    end
    instance_variable_get(f).walk(path)
  end

  def keys
    to_h.keys
  end
end

class CommandLineTool < CWLObject
  cwl_object_preamble :inputs, :outputs, :class_, :id, :requirements,
                      :hints, :label, :doc, :cwlVersion, :baseCommand,
                      :arguments, :stdin, :stderr, :stdout, :successCodes,
                      :temporaryFailCodes, :permanentFailCodes

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      ['inputs', 'outputs', 'class'].all?{ |f| obj.include? f } and
      obj['class'] == 'CommandLineTool'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @inputs = if obj['inputs'].instance_of? Array
                obj['inputs'].map{ |o|
                  CommandInputParameter.load(o)
                }
              else
                obj['inputs'].map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'id' => k,
                          'type' => v,
                        }
                      else
                        o = {}
                        o['id'] = k
                        v.each{ |f, val|
                          o[f] = val
                        }
                        o
                      end
                  CommandInputParameter.load(o)
                }
              end

    @outputs = if obj['outputs'].instance_of? Array
                 obj['outputs'].map{ |o|
                   CommandOutputParameter.load(o)
                 }
               else
                 obj['outputs'].map{ |k, v|
                   o = if v.instance_of? String or
                         v.instance_of? Array or
                         ['record', 'enum', 'array'].include? v.fetch('type', nil)
                         {
                           'id' => k,
                           'type' => v,
                         }
                       else
                         o = {}
                         o['id'] = k
                         v.each{ |f, val|
                           o[f] = val
                         }
                         o
                       end
                   CommandOutputParameter.load(o)
                 }
               end

    @class_ = obj['class']
    @id = obj.fetch('id', nil)
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               o = {}
               o['class'] = k
               v.each{ |f, val|
                 o[f] = val
               }
               o
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                o = {}
                o['class'] = k
                v.each{ |f, val|
                  o[f] = val
                }
                o
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h)
    }
    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @cwlVersion = obj.fetch('cwlVersion', nil)
    @baseCommand = if obj.fetch('baseCommand', []).instance_of? Array
                     obj.fetch('baseCommand', [])
                   else
                     [obj['baseCommand']]
                   end
    @arguments = obj.fetch('arguments', []).map{ |arg|
      if arg.instance_of? Hash
        CommandLineBinding.load(arg)
      else
        CommandLineBinding.load({ 'valueFrom' => arg, })
      end
    }
    @stdin = obj.include?('stdin') ? Expression.load(obj['stdin']) : nil
    @stderr = if obj.include?('stderr')
                Expression.load(obj['stderr'])
              elsif @outputs.index{ |o| o.type.instance_of? Stderr }
                Expression.load(SecureRandom.alphanumeric+'.stderr')
              else
                nil
              end
    @stdout = if obj.include?('stdout')
                Expression.load(obj['stdout'])
              elsif @outputs.index{ |o| o.type.instance_of? Stdout }
                Expression.load(SecureRandom.alphanumeric+'.stdout')
              else
                nil
              end
    @successCodes = obj.fetch('successCodes', [])
    @temporaryFailCodes = obj.fetch('temporaryFailCodes', [])
    @permanentFailCodes = obj.fetch('permanentFailCodes', [])
  end

  def self.load_requirement(req)
    unless req.include? 'class'
      raise CWLParseError, 'Invalid requriment object'
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req)
    when 'DockerRequirement'
      DockerRequirement.load(req)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req)
    when 'ResourceRequirement'
      ResourceRequirement.load(req)
    else
      raise CWLParseError, "Invalid requirement: #{req['class']}"
    end
  end

  def to_h
    ret = {}
    ret['inputs'] = @inputs.map{ |input|
      input.to_h
    }
    ret['outputs'] = @outputs.map{ |out|
      out.to_h
    }
    ret['class'] = @class_
    unless @id.nil?
      ret['id'] = @id
    end

    unless @requirements.empty?
      ret['requirements'] = @requirements.map{ |req|
        req.to_h
      }
    end

    unless @hints.empty?
      ret['hints'] = @hints.map{ |h|
        h.to_h
      }
    end

    ret['label'] = @label unless @label.nil?
    ret['doc'] = @doc unless @doc.nil?
    ret['cwlVersion'] = @cwlVersion unless @cwlVersion.nil?
    ret['baseCommand'] = @baseCommand unless @baseCommand.empty?

    unless @arguments.empty?
      ret['arguments'] = @arguments.map{ |a|
        a.to_h
      }
    end

    ret['stdin'] = @stdin.to_h unless @stdin.nil?
    ret['stderr'] = @stderr.to_h unless @stderr.nil?
    ret['stdout'] = @stdout.to_h unless @stdout.nil?
    ret['successCodes'] = @successCodes unless @successCodes.empty?
    ret['temporaryFailCodes'] = @temporaryFailCodes unless @temporaryFailCodes.empty?
    ret['permanentFailCodes'] = @permanentFailCodes unless @permanentFailCodes.empty?
    ret
  end
end

class CommandInputParameter < CWLObject
  cwl_object_preamble :id, :label, :secondaryFiles, :streamable,
                      :doc, :format, :inputBinding, :default, :type

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      ['id'].all?{ |f| obj.include? f }
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'])]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @format = if obj.fetch('format', []).instance_of? Array
                obj.fetch('format', []).map{ |f|
                  Expression.load(f)
                }
              else
                [Expression.load(obj['format'])]
              end
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
    @type = if obj.include? 'type'
              CWLCommandInputType.load(obj['type'])
            end
    @default = if obj.include? 'default'
                 if @type.nil?
                   raise CWLParseError, 'Unsupported syntax: `default` without `type`'
                 end
                 InputParameter.parse_object(@type, obj['default'])
               end
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['label'] = @label unless @label.nil?
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |f|
        f.to_h
      }
    end
    ret['streamable'] = @streamable if @streamable
    ret['doc'] = @doc if @doc.nil? or @doc.empty?
    unless @format.empty?
      ret['format'] = @format.map{ |f|
        f.to_h
      }
    end
    unless @inputBinding.nil?
      ret['inputBinding'] = @inputBinding.to_h
    end
    ret['default'] = @default.to_h unless @default.nil?
    ret['type'] = @type.to_h unless @type.nil?
    ret
  end
end

class CommandLineBinding < CWLObject
  cwl_object_preamble :loadContents, :position, :prefix, :separate,
                      :itemSeparator, :valueFrom, :shellQuote

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @loadContents = obj.fetch('loadContents', false)
    @position = obj.fetch('position', 0)
    @prefix = obj.fetch('prefix', nil)
    @separate = obj.fetch('separate', true)
    @itemSeparator = obj.fetch('itemSeparator', nil)
    @valueFrom = if obj.include? 'valueFrom'
                   Expression.load(obj['valueFrom'])
                 end
    @shellQuote = obj.fetch('shellQuote', true)
  end

  def to_h
    ret = {}
    ret['loadContents'] = @loadContents if @loadContents
    ret['position'] = @position
    ret['prefix'] = @prefix unless @prefix.nil?
    ret['separate'] = @separate unless @separate
    ret['itemSeparator'] = @itemSeparator unless @itemSeparator.nil?
    ret['valueFrom'] = @valueFrom.to_h unless @valueFrom.nil?
    ret['shellQuote'] = @shellQuote unless @shellQuote
    ret
  end
end

class CWLType
  attr_reader :type

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    @type = obj
  end

  def walk(path)
    if path.empty?
      @type
    else
      raise CWLParseError, "No such field for #{@type}: #{path}"
    end
  end

  def to_h
    @type
  end
end

class CWLInputType
  def self.load(obj)
    case obj
    when Array
      InputUnionSchema.load(obj)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        InputRecordSchema.load(obj)
      when 'enum'
        InputEnumSchema.load(obj)
      when 'array'
        InputArraySchema.load(obj)
      end
    when /^(.+)\?$/
      InputUnionSchema.load([$1, 'null'])
    when /^(.+)\[\]$/
      InputArraySchema.load({
                              'type' => 'array',
                              'items' => $1,
                            })
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory'
      CWLType.load(obj)
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end
end

class CWLCommandInputType
  def self.load(obj)
    case obj
    when Array
      CommandInputUnionSchema.load(obj)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        CommandInputRecordSchema.load(obj)
      when 'enum'
        CommandInputEnumSchema.load(obj)
      when 'array'
        CommandInputArraySchema.load(obj)
      end
    when /^(.+)\?$/
      CommandInputUnionSchema.load([$1, 'null'])
    when /^(.+)\[\]$/
      CommandInputArraySchema.load({
                                     'type' => 'array',
                                     'items' => self.load($1),
                                   })
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory'
      CWLType.load(obj)
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end
end

class CWLOutputType
  def self.load(obj)
    case obj
    when Array
      OutputUnionSchema.load(obj)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        OutputRecordSchema.load(obj)
      when 'enum'
        OutputEnumSchema.load(obj)
      when 'array'
        OutputArraySchema.load(obj)
      end
    when /^(.+)\?$/
      OutputUnionSchema.load([$1, 'null'])
    when /^(.+)\[\]$/
      OutputArraySchema.load({
                               'type' => 'array',
                               'items' => $1,
                             })
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory'
      CWLType.load(obj)
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end
end

class CWLCommandOutputType
  def self.load(obj)
    case obj
    when Array
      CommandOutputUnionSchema.load(obj)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        CommandOutputRecordSchema.load(obj)
      when 'enum'
        CommandOutputEnumSchema.load(obj)
      when 'array'
        CommandOutputArraySchema.load(obj)
      end
    when /^(.+)\?$/
      CommandOutputUnionSchema.load([$1, 'null'])
    when /^(.+)\[\]$/
      CommandOutputArraySchema.load({
                                     'type' => 'array',
                                     'items' => $1,
                                   })
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory'
      CWLType.load(obj)
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end
end


class CWLFile < CWLObject
  cwl_object_preamble :class_, :location, :path, :basename, :dirname,
                      :nameroot, :nameext, :checksum, :size,
                      :secondaryFiles, :format, :contents
  attr_writer :location, :path, :basename, :dirname,
              :nameroot, :nameext, :checksum, :size,
              :secondaryFiles, :format, :contents

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'File'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @location = obj.fetch('location', nil)
    @path = obj.fetch('path', nil)
    @basename = nil
    @dirname = nil
    @nameroot = nil
    @nameext = nil
    @checksum = nil
    @size = nil
    @secondaryFiles = obj.fetch('secondaryFiles', []).map{ |f|
      case f.fetch('class', '')
      when 'File'
        CWLFile.load(f)
      when 'Directory'
        Directory.load(f)
      else
        raise CWLParseError, "Cannot parse as #{self.class}"
      end
    }
    @format = obj.fetch('format', nil)
    @contents = nil
  end

  def evaluate(runtime, loadContents = false, strict = true)
    file = self.dup
    location = @location.nil? ? @path : @location
    if location.nil?
      if @contents.empty?
        raise CWLInspectionError, "`path`, `location` or `contents` is necessary for File object: #{self}"
      end
      raise CWLInspectionError, "Unsupported"
      # If the location field is not provided, the contents field must be provided. The implementation must assign a unique identifier for the location field.
    end

    file.location, file.path = case location
                               when %r|^(.+:)//(.+)$|
                                 scheme, path = $1, $2
                                 case scheme
                                 when 'file:'
                                   unless File.exist? path
                                     raise CWLInspectionError, "File not found: #{location}"
                                   end
                                   [location, path]
                                 when 'http:', 'https:', 'ftp:'
                                   raise CWLInspectionError, "Unsupported scheme: #{scheme}"
                                 else
                                   raise CWLInspectionError, "Unsupported scheme: #{scheme}"
                                 end
                               else
                                 path = File.expand_path(location, runtime['docdir'].first)
                                 unless File.exist? path
                                   raise CWLInspectionError, "File not found: file://#{path}" if strict
                                 end
                                 ['file://'+path, path]
                               end
    file.basename = File.basename file.path
    file.dirname = File.dirname file.path
    file.nameext = File.extname file.path
    file.nameroot = File.basename file.path, file.nameext
    if strict
      digest = Digest::SHA1.hexdigest(File.open(file.path, 'rb').read)
      file.checksum = "sha1$#{digest}"
      file.size = File.size(file.path)
    end
    file.secondaryFiles = @secondaryFiles.map{ |sf|
      sf.evaluate(runtime, loadContents, strict)
    }
    file.contents = if @contents
                      @contents
                    elsif loadContents and strict
                      File.open(file.path).read(64*2**10)
                    end
    file.format = @format
    file
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['location'] = @location unless @location.nil?
    ret['path'] = @path unless @path.nil?
    ret['basename'] = @basename unless @basename.nil?
    ret['dirname'] = @dirname unless @dirname.nil?
    ret['nameroot'] = @nameroot unless @nameroot.nil?
    ret['nameext'] = @nameext unless @nameext.nil?
    ret['checksum'] = @checksum unless @checksum.nil?
    ret['size'] = @size unless @size.nil?
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |f|
        f.to_h
      }
    end
    ret['format'] = @format unless @format.nil?
    ret['contents'] = @contents unless @contents.nil?
    ret
  end
end

class Directory < CWLObject
  cwl_object_preamble :class_, :location, :path, :basename, :listing
  attr_writer :location, :path, :basename, :listing

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'Directory'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @location = obj.fetch('location', nil)
    @path = obj.fetch('path', nil)
    @basename = nil
    @listing = obj.fetch('listing', []).map{ |f|
      case f.fetch('class', '')
      when 'File'
        CWLFile.load(f)
      when 'Directory'
        Directory.load(f)
      else
        raise CWLParseError, "Cannot parse as #{self.class}"
      end
    }
  end

  def evaluate(runtime, loadContents = false, strict = true)
    dir = self.dup
    location = @location.nil? ? @path : @location
    if @location.nil?
      if @listing.empty?
        raise CWLInspectionError, "`path`, `location` or `listing` fields is necessary for Directory object: #{self}"
      end
      raise CWLInspectionError, "Unsupported"
    end

    dir.location, dir.path = if location.match %r|^(.+:)//(.+)$|
                               scheme, path = $1, $2
                               case scheme
                               when 'file:'
                                 unless Dir.exist? path
                                   raise CWLInspectionError, "Directory not found: #{location}"
                                 end
                                 [location, path]
                               when 'http:', 'https:', 'ftp:'
                                 raise CWLInspectionError, "Unsupported scheme: #{scheme}"
                               else
                                 raise CWLInspectionError, "Unsupported scheme: #{scheme}"
                               end
                             else
                               unless Dir.exist? location
                                 raise CWLInspectionError, "Directory not found: #{location}" if strict
                               end
                               path = File.expand_path(location, runtime['docdir'].first)
                               ['file://'+path, path]
                             end
    dir.basename = File.basename dir.path
    dir.listing = @listing.map{ |lst|
      lst.evaluate(runtime, loadContents, strict)
    }
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['location'] = @location unless @location.nil?
    ret['path'] = @path unless @path.nil?
    ret['basename'] = @basename unless @basename.nil?
    unless @listing.empty?
      ret['listing'] = @listing.map{ |lst|
        lst.to_h
      }
    end
    ret
  end
end

class CommandInputUnionSchema < CWLObject
  attr_reader :types

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless obj.instance_of? Array
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @types = obj.map{ |o|
      CWLCommandInputType.load(o)
    }
  end

  def walk(path)
    @types.walk(path)
  end

  def to_h
    @types.map{ |t|
      t.to_h
    }
  end
end

class CommandInputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = obj.fetch('fields', []).map{ |f|
      CommandInputRecordField.load(f)
    }
    @label = obj.fetch('label', nil)
  end

  def to_h
    ret = {}
    ret['type'] = @type
    unless @fields.empty?
      ret['fields'] = @fields.map{ |f|
        f.to_h
      }
    end
    ret['label'] = @label unless @label.nil?
    ret
  end
end

class CommandInputRecordField < CWLObject
  cwl_object_preamble :name, :type, :doc, :inputBinding, :label

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('name') and
      obj.include?('type')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLCommandInputType.load(obj['type'])
    @doc = obj.fetch('doc', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
    @label = obj.fetch('label', nil)
  end

  def to_h
    ret = {}
    ret['name'] = @name
    ret['type'] = @type.to_h
    ret['doc'] = @doc unless @doc.nil?
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret['label'] = @label unless @label.nil?
    ret
  end
end

class CommandInputEnumSchema < CWLObject
  cwl_object_preamble :symbols, :type, :label, :inputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('symbols') and
      obj.fetch('type', '') == 'enum'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
  end

  def to_h
    ret = {}
    ret['symbols'] = @symbols
    ret['type'] = @type
    ret['label'] = @label unless @label.nil?
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret
  end
end

class CommandInputArraySchema < CWLObject
  cwl_object_preamble :items, :type, :label, :inputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('items') and
      obj.fetch('type', '') == 'array'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @items = CWLCommandInputType.load(obj['items'])
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
  end

  def to_h
    ret = {}
    ret['items'] = @items.to_h
    ret['type'] = @type
    ret['label'] = @label unless @label.nil?
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret
  end
end

class CommandOutputParameter < CWLObject
  cwl_object_preamble :id, :label, :secondaryFiles, :streamable,
                      :doc, :outputBinding, :format, :type

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include? 'id'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |f|
                          Expression.load(f)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'])]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
    @format = if obj.include? 'format'
                Expression.load(obj['format'])
              end
    @type = if obj.include? 'type'
              case obj['type']
              when 'stdout'
                Stdout.load(obj['type'])
              when 'stderr'
                Stderr.load(obj['type'])
              else
                CWLCommandOutputType.load(obj['type'])
              end
            end
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['label'] = @label unless @label.nil?
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |f|
        f.to_h
      }
    end
    ret['streamable'] = @streamable if @streamable
    ret['doc'] = @doc unless @doc.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret['format'] = @format unless @format.nil?
    ret['type'] = @type.to_h unless @type.nil?
    ret
  end
end

class Stdout
  def self.load(obj)
    self.new
  end

  def walk(path)
    if path.empty?
      'stdout'
    else
      raise CWLParseError, "No such field for stdout: #{path}"
    end
  end

  def to_h
    'stdout'
  end
end

class Stderr
  def self.load(obj)
    self.new
  end

  def walk(path)
    if path.empty?
      'stderr'
    else
      raise CWLParseError, "No such field for stderr: #{path}"
    end
  end

  def to_h
    'stderr'
  end
end

class CommandOutputBinding < CWLObject
  cwl_object_preamble :glob, :loadContents, :outputEval

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @glob = if obj.fetch('glob', []).instance_of? Array
              obj.fetch('glob', [])
            else
              [Expression.load(obj['glob'])]
            end

    @loadContents = obj.fetch('loadContents', false)
    @outputEval = if obj.include? 'outputEval'
                    Expression.load(obj['outputEval'])
                  end
  end

  def to_h
    ret = {}
    unless @glob.empty?
      ret['glob'] = @glob.map{ |g|
        g.to_h
      }
    end
    ret['loadContents'] = @loadContents if @loadContents
    ret['outputEval'] = @outputEval.to_h unless @outputEval.nil?
    ret
  end
end

class CommandOutputUnionSchema < CWLObject
  attr_reader :types

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless obj.instance_of? Array
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @types = obj.map{ |o|
      CWLCommandOutputType.load(o)
    }
  end

  def walk(path)
    @types.walk(path)
  end

  def to_h
    @types.map{ |t|
      t.to_h
    }
  end
end

class CommandOutputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = obj.fetch('fields', []).map{ |f|
      CommandOutputRecordField.load(f)
    }
    @label = obj.fetch('label', nil)
  end

  def to_h
    ret = {}
    ret['type'] = @type
    unless @fields.empty?
      ret['fields'] = @fields.map{ |f|
        f.to_h
      }
    end
    ret['label'] = @label unless @label.nil?
    ret
  end
end

class CommandOutputRecordField < CWLObject
  cwl_object_preamble :name, :type, :doc, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('name') and
      obj.include?('type')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLCommandOutputType.load(obj['type'])
    @doc = obj.fetch('doc', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
  end

  def to_h
    ret = {}
    ret['name'] = @name
    ret['type'] = @type.to_h
    ret['doc'] = @doc unless @doc.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret
  end
end

class CommandOutputEnumSchema < CWLObject
  cwl_object_preamble :symbols, :type, :label, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('symbols') and
      obj.fetch('type', '') == 'enum'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
  end

  def to_h
    ret = {}
    ret['symbols'] = @symbols
    ret['type'] = @type
    ret['label'] = @label unless @label.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret
  end
end

class CommandOutputArraySchema < CWLObject
  cwl_object_preamble :items, :type, :label, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('items') and
      obj.fetch('type', '') == 'array'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @items = CWLCommandOutputType.load(obj['items'])
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
  end

  def to_h
    ret = {}
    ret['items'] = @items.to_h
    ret['type'] = @type
    ret['label'] = @label unless @label.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret
  end
end

class InlineJavascriptRequirement < CWLObject
  cwl_object_preamble :class_, :expressionLib

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', 'InlineJavascriptRequirement')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @expressionLib = obj.fetch('expressionLib', [])
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    unless @expressionLib.empty?
      ret['expressionLib'] = @expressionLib
    end
    ret
  end
end

class SchemaDefRequirement < CWLObject
  cwl_object_preamble :class_, :types

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', 'SchemaDefRequirement') and
      obj.include? 'types'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @types = obj['types'].map{ |t|
      self.class.load_input_type(t)
    }
  end

  def self.load_input_type(obj)
    unless obj.instance_of?(Hash) and
          obj.include? 'type'
      raise CWLParseError, 'Invalid type object: #{obj}'
    end

    case obj['type']
    when 'record'
      InputRecordSchema.load(obj)
    when 'enum'
      InputEnumSchema.load(obj)
    when 'array'
      InputArraySchema.load(obj)
    end
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['types'] = @types.map{ |t|
      t.to_h
    }
    ret
  end
end

class InputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = obj.fetch('fields', []).map{ |f|
      InputRecordField.load(f)
    }
    @label = obj.fetch('label', nil)
  end

  def to_h
    ret = {}
    ret['type'] = @type
    unless @fields.empty?
      ret['fields'] = @fields.map{ |f|
        f.to_h
      }
    end
    ret['label'] = @label unless @label.nil?
    ret
  end
end

class InputRecordField < CWLObject
  cwl_object_preamble :name, :type, :doc, :inputBinding, :label

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('name') and
      obj.include?('type')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLInputType.load(obj['type'])
    @doc = obj.fetch('doc', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
    @label = obj.fetch('label', nil)
  end

  def to_h
    ret = {}
    ret['name'] = @name
    ret['type'] = @type.to_h
    ret['doc'] = @doc unless @doc.nil?
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret['label'] = @label unless @label.nil?
    ret
  end
end

class InputEnumSchema < CWLObject
  cwl_object_preamble :symbols, :type, :label, :inputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('symbols') and
      obj.fetch('type', '') == 'enum'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
  end

  def to_h
    ret = {}
    ret['symbols'] = @symbols
    ret['type'] = @type
    ret['label'] = @label unless @label.nil?
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret
  end
end

class InputArraySchema < CWLObject
  cwl_object_preamble :items, :type, :label, :inputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('items') and
      obj.fetch('type', '') == 'array'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @items = CWLInputType.load(obj['items'])
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
  end

  def to_h
    ret = {}
    ret['items'] = @items.to_h
    ret['type'] = @type
    ret['label'] = @label unless @label.nil?
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret
  end
end

class DockerRequirement < CWLObject
  cwl_object_preamble :class_, :dockerPull, :dockerLoad, :dockerFile,
                      :dockerImport, :dockerImageId, :dockerOutputDirectory

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'DockerRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @dockerPull = obj.fetch('dockerPull', nil)
    @dockerLoad = obj.fetch('dockerLoad', nil)
    @dockerFile = obj.fetch('dockerFile', nil)
    @dockerImport = obj.fetch('dockerImport', nil)
    @dockerImageId = obj.fetch('dockerImageId', nil)
    @dockerOutputDirectory = obj.fetch('dockerOutputDirectory', nil)
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['dockerPull'] = @dockerPull unless @dockerPull.nil?
    ret['dockerLoad'] = @dockerLoad unless @dockerLoad.nil?
    ret['dockerFile'] = @dockerFile unless @dockerFile.nil?
    ret['dockerImport'] = @dockerImport unless @dockerImport.nil?
    ret['dockerImageId'] = @dockerImageId unless @dockerImageId.nil?
    ret['dockerOutputDirectory'] = @dockerOutputDirectory unless @dockerOutputDirectory.nil?
    ret
  end
end

class SoftwareRequirement < CWLObject
  cwl_object_preamble :class_, :packages

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'SoftwareRequirement' and
      obj.include? 'packages'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @packages = if obj['packages'].instance_of? Array
                  obj['packages'].map{ |p|
                    SoftwarePackage.load(p)
                  }
                else
                  ps = obj['packages']
                  packages = if ps.values.first.instance_of? Hash
                               ps.map{ |k, v|
                                 o = {}
                                 o['package'] = k
                                 v.each{ |f, val|
                                   o[f] = val
                                 }
                                 o
                               }
                             else
                               ps.map{ |k, v|
                                 {
                                   'package' => k,
                                   'specs' => v,
                                 }
                               }
                             end
                  packages.map{ |p|
                    SoftwarePackage.load(p)
                  }
                end
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['packages'] = @packages.map{ |p|
      p.to_h
    }
    ret
  end
end

class SoftwarePackage < CWLObject
  cwl_object_preamble :package, :version, :specs

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include? 'package'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @package = obj['package']
    @version = obj.fetch('version', [])
    @specs = obj.fetch('specs', [])
  end

  def to_h
    ret = {}
    ret['package'] = @package
    unless @version.empty?
      ret['version'] = @version
    end
    unless @specs.empty?
      ret['specs'] = @specs
    end
    ret
  end
end

class InitialWorkDirRequirement < CWLObject
  cwl_object_preamble :class_, :listing

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'InitialWorkDirRequirement' and
      obj.include? 'listing'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @listing = if obj['listing'].instance_of? Array
                 obj['listing'].map{ |lst|
                   self.class.load_list(lst)
                 }
               else
                 Expression.load(obj['listing'])
               end
  end

  def self.load_list(obj)
    if obj.instance_of? String
      Expression.load(obj)
    else
      case obj.fetch('class', 'Dirent')
      when 'File'
        CWLFile.load(obj)
      when 'Directory'
        Directory.load(obj)
      when 'Dirent'
        Dirent.load(obj)
      end
    end
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['listing'] = @listing.map{ |lst|
      lst.to_h
    }
    ret
  end
end

class Dirent < CWLObject
  cwl_object_preamble :entry, :entryname, :writable

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include? 'entry'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @entry = Expression.load(obj['entry'])
    @entryname = if obj.include? 'entryname'
                   Expression.load(obj['entryname'])
                 end
    @writable = obj.fetch('writable', false)
  end

  def to_h
    ret = {}
    ret['entry'] = @entry.to_h
    ret['entryname'] = @entryname.to_h unless @entryname.nil?
    ret['writable'] = @writable if @writable
    ret
  end
end

class EnvVarRequirement < CWLObject
  cwl_object_preamble :class_, :envDef

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'EnvVarRequirement' and
      obj.include? 'envDef'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @envDef = if obj['envDef'].instance_of? Array
                obj['envDef'].map{ |env|
                  EnvironmentDef.load(env)
                }
              else
                defs = obj['envDef']
                if defs.values.first.instance_of? String
                  defs.map{ |k, v|
                    EnvironmentDef.load({
                                          'envName' => k,
                                          'envValue' => v,
                                        })
                  }
                else
                  defs.map{ |k, v|
                    d = {}
                    d['envName'] = k
                    v.each{ |f, val|
                      d[f] = val
                    }
                    EnvironmentDef.load(d)
                  }
                end
              end
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['envDef'] = @envDef.map{ |env|
      env.to_h
    }
    ret
  end
end

class EnvironmentDef < CWLObject
  cwl_object_preamble :envName, :envValue

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('envName') and
      obj.include? 'envValue'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @envName = obj['envName']
    @envValue = Expression.load(obj['envValue'])
  end

  def to_h
    ret = {}
    ret['envName'] = @envName
    ret['envValue'] = @envValue.to_h
    ret
  end
end

class ShellCommandRequirement < CWLObject
  cwl_object_preamble :class_

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'ShellCommandRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret
  end
end

class ResourceRequirement < CWLObject
  cwl_object_preamble :class_, :coresMin, :coresMax, :ramMin, :ramMax,
                      :tmpdirMin, :tmpdirMax, :outdirMin, :outdirMax

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'ResourceRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @coresMin = if obj.include? 'coresMin'
                  if obj['coresMin'].instance_of? String
                    Expression.load(obj['coresMin'])
                  else
                    obj['coresMin']
                  end
                end
    @coresMax = if obj.include? 'coresMax'
                  if obj['coresMax'].instance_of? String
                    Expression.load(obj['coresMax'])
                  else
                    obj['coresMax']
                  end
                end
    @ramMin = if obj.include? 'ramMin'
                if obj['ramMin'].instance_of? String
                  Expression.load(obj['ramMin'])
                else
                  obj['ramMin']
                end
              end
    @ramMax = if obj.include? 'ramMax'
                if obj['ramMax'].instance_of? String
                  Expression.load(obj['ramMax'])
                else
                  obj['ramMax']
                end
              end
    @tmpdirMin = if obj.include? 'tmpdirMin'
                   if obj['tmpdirMin'].instance_of? String
                     Expression.load(obj['tmpdirMin'])
                   else
                     obj['tmpdirMin']
                   end
                 end
    @tmpdirMax = if obj.include? 'tmpdirMax'
                   if obj['tmpdirMax'].instance_of? String
                     Expression.load(obj['tmpdirMax'])
                   else
                     obj['tmpdirMax']
                   end
                 end
    @outdirMin = if obj.include? 'outdirMin'
                   if obj['outdirMin'].instance_of? String
                     Expression.load(obj['outdirMin'])
                   else
                     obj['outdirMin']
                   end
                 end
    @outdirMax = if obj.include? 'outdirMax'
                   if obj['outdirMax'].instance_of? String
                     Expression.load(obj['outdirMax'])
                   else
                     obj['outdirMax']
                   end
                 end
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    unless @coresMin.nil?
      ret['coresMin'] = if @coresMin.instance_of? Expression
                          @coresMin.to_h
                        else
                          @coresMin
                        end
    end
    unless @coresMax.nil?
      ret['coresMax'] = if @coresMax.instance_of? Expression
                          @coresMax.to_h
                        else
                          @coresMax
                        end
    end
    unless @ramMin.nil?
      ret['ramMin'] = if @ramMin.instance_of? Expression
                          @ramMin.to_h
                        else
                          @ramMin
                        end
    end
    unless @ramMax.nil?
      ret['ramMax'] = if @ramMax.instance_of? Expression
                          @ramMax.to_h
                        else
                          @ramMax
                        end
    end
    unless @tmpdirMin.nil?
      ret['tmpdirMin'] = if @tmpdirMin.instance_of? Expression
                          @tmpdirMin.to_h
                        else
                          @tmpdirMin
                        end
    end
    unless @tmpdirMax.nil?
      ret['tmpdirMax'] = if @tmpdirMax.instance_of? Expression
                          @tmpdirMax.to_h
                        else
                          @tmpdirMax
                        end
    end
    unless @outdirMin.nil?
      ret['outdirMin'] = if @outdirMin.instance_of? Expression
                          @outdirMin.to_h
                        else
                          @outdirMin
                        end
    end
    unless @outdirMax.nil?
      ret['outdirMax'] = if @outdirMax.instance_of? Expression
                          @outdirMax.to_h
                        else
                          @outdirMax
                        end
    end
    ret
  end
end

def evaluate_parameter_reference(exp, inputs, runtime, self_)
  case exp
  when /^inputs\.(.+)$/
    body = $1
    param, rest = body.match(/([^.]+)(\..+)?$/).values_at(1, 2)
    obj = inputs[param]
    obj.walk(rest[1..-1].split(/\.|\[|\]\.|\]/))
  when /^self\.(.+)$/
    rest = $1
    if self_.nil?
      raise CWLInspectionError, "Unknown context for self in the expression: #{exp}"
    end
    self_.walk(rest[1..-1].split(/\.|\[|\]\.|\]/))
  when /^runtime\.(.+)$/
    attr = $1
    if runtime.reject{ |k, _| k == 'docdir' }.include? attr
      runtime[attr]
    else
      raise CWLInspectionError, "Unknown parameter reference: #{exp}"
    end
  else
    raise CWLInspectionError, "Unknown parameter reference: #{exp}"
  end
end

def node_bin
  # TODO: using user specified nodejs executable
  node = ['node', 'nodejs'].find{ |n|
    system("which #{n} > /dev/null")
  }
  raise "No executables for Nodejs" if node.nil?
  node
end

def evaluate_js_expression(expression, kind, inputs, runtime, self_)
  node = node_bin
  exp = kind == :expression ? expression : "(function() { #{expression.gsub(/\n/, '\n')} })()"
  exp = exp.gsub(/"/, '\"')
  cmdstr = <<-EOS
  'use strict'
  try{
    const exp = "#{exp}";
    process.stdout.write(JSON.stringify(require('vm').runInNewContext(exp, {
      'runtime': #{JSON.dump(runtime.reject{ |k, _| k == 'docdir' })},
      'inputs': #{JSON.dump(inputs)},
      'self': #{JSON.dump(self_)}
    })));
  } catch(e) {
    process.stdout.write(JSON.stringify({ 'class': 'exception', 'message': `${e.name}: ${e.message}`}))
  }
EOS
  ret = JSON.load(IO.popen([node, '--eval', cmdstr]) { |io| io.gets })
  if ret.instance_of?(Hash) and
    ret.fetch('class', '') == 'exception'
    e = kind == :expression ? "$(#{expression})" : "${#{expression}}"
    raise CWLInspectionError, "#{ret['message']} in expression '#{e}'"
  end
  # parse object
  ret
end

class Expression
  def self.load(obj)
    Expression.new(obj)
  end

  def initialize(exp)
    @expression = exp
  end

  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end

  def evaluate(use_js, inputs, runtime, self_ = nil)
    expression = @expression.chomp

    rx = use_js ? /\$([({])/ : /\$\(/
    exp_parser = ECMAScriptExpressionParser.new
    fun_parser = ECMAScriptFunctionBodyParser.new
    ref_parser = ParameterReferenceParser.new

    evaled = nil
    while expression.match rx
      kind = $1 == '(' ? :expression : :body
      parser = if use_js
                 case kind
                 when :expression
                   exp_parser
                 when :body
                   fun_parser
                 end
               else
                 ref_parser
               end
      begin
        m = parser.parse expression
        exp = m[:body].to_s
        pre = m[:pre].instance_of?(Array) ? '' : m[:pre].to_s
        post = m[:post].instance_of?(Array) ? '' : m[:post].to_s
        ret = if use_js
                evaluate_js_expression(exp, kind, inputs, runtime, self_)
              else
                evaluate_parameter_reference(exp, inputs, runtime, self_)
              end
        evaled = if evaled.nil? and pre.empty?
                   ret
                 else
                   "#{evaled}#{pre}#{ret}"
                 end
        expression = post
      rescue Parslet::ParseFailed
        str = use_js ? 'Javascript expression' : 'parameter reference'
        raise CWLInspectionError, "Invalid #{str}: #{expression}"
      end
    end
    if evaled.nil?
      expression
    elsif expression.empty?
      evaled
    else
      "#{evaled}#{expression}"
    end
  end

  def to_h
    @expression
  end
end

class CWLVersion
  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(String) and
      ['draft-2', 'draft-3.dev1', 'draft-3.dev2',
       'draft-3.dev3', 'draft-3.dev4', 'draft-3.dev5',
       'draft-3', 'draft-4.dev1', 'draft-4.dev2',
       'draft-4.dev3', 'v1.0.dev4', 'v1.0'].include? obj
  end

  def self.load(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self}"
    end
    obj
  end
end

class Workflow < CWLObject
  cwl_object_preamble :inputs, :outputs, :class_, :steps, :id, :requirements,
                      :hints, :label, :doc, :cwlVersion

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      ['inputs', 'outputs', 'class', 'steps'].all?{ |f| obj.include? f } and
      obj['class'] == 'Workflow'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @inputs = if obj['inputs'].instance_of? Array
                obj['inputs'].map{ |o|
                  InputParameter.load(o)
                }
              else
                obj['inputs'].map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'id' => k,
                          'type' => v,
                        }
                      else
                        o = {}
                        o['id'] = k
                        v.each{ |f, val|
                          o[f] = val
                        }
                        o
                      end
                  InputParameter.load(o)
                }
              end

    @outputs = if obj['outputs'].instance_of? Array
                 obj['outputs'].map{ |o|
                   WorkflowOutputParameter.load(o)
                 }
               else
                 obj['outputs'].map{ |k, v|
                   o = if v.instance_of? String or
                         v.instance_of? Array or
                         ['record', 'enum', 'array'].include? v.fetch('type', nil)
                         {
                           'id' => k,
                           'type' => v,
                         }
                       else
                         o = {}
                         o['id'] = k
                         v.each{ |f, val|
                           o[f] = val
                         }
                         o
                       end
                   WorkflowOutputParameter.load(o)
                 }
               end
    @class_ = obj['class']
    @steps = if obj['steps'].instance_of? Array
               obj['steps'].map{ |s|
                 WorkflowStep.load(s)
               }
             else
               obj['steps'].map{ |k, v|
                 o = {}
                 o['id'] = k
                 v.each{ |f, val|
                   o[f] = val
                 }
                 WorkflowStep.load(o)
               }
             end
    @id = obj.fetch('id', nil)
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               o = {}
               o['class'] = k
               v.each{ |f, val|
                 o[f] = val
               }
               o
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                o = {}
                o['class'] = k
                v.each{ |f, val|
                  o[f] = val
                }
                o
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h)
    }

    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @cwlVersion = obj.fetch('cwlVersion', nil)
  end

  def self.load_requirement(req)
    unless req.include? 'class'
      raise CWLParseError, 'Invalid requriment object'
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req)
    when 'DockerRequirement'
      DockerRequirement.load(req)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req)
    when 'ResourceRequirement'
      ResourceRequirement.load(req)
    when 'SubworkflowFeatureRequirement'
      SubworkflowFeatureRequirement.load(req)
    when 'ScatterFeatureRequirement'
      ScatterFeatureRequirement.load(req)
    when 'MultipleInputFeatureRequirement'
      MultipleInputFeatureRequirement.load(req)
    when 'StepInputExpressionRequirement'
      StepInputExpressionRequirement.load(req)
    else
      raise CWLParseError, "Invalid requirement: #{req['class']}"
    end
  end

  def to_h
    ret = {}
    ret['inputs'] = @inputs.map{ |inp|
      inp.to_h
    }
    ret['outputs'] = @outputs.map{ |out|
      out.to_h
    }
    ret['class'] = @class_
    ret['steps'] = @steps.map{ |st|
      st.to_h
    }
    unless @id.nil?
      ret['id'] = @id
    end

    unless @requirements.empty?
      ret['requirements'] = @requirements.map{ |r|
        r.to_h
      }
    end

    unless @hints.empty?
      ret['hints'] = @hints.map{ |h|
        h.to_h
      }
    end

    unless @label.nil?
      ret['label'] = @label
    end

    unless @doc.nil?
      ret['doc'] = @doc
    end

    unless @cwlVersion.nil?
      ret['cwlVersion'] = @cwlVersion
    end
    ret
  end
end

class WorkflowOutputParameter < CWLObject
  cwl_object_preamble :id, :label, :secondaryFiles, :streamable,
                      :doc, :outputBinding, :format, :outputSource,
                      :linkMerge, :type

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      ['id'].all?{ |f| obj.include? f }
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'])]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
    @format = if obj.include? 'format'
                Expression.load(obj['format'])
              end
    @outputSource = if obj.fetch('outputSource', []).instance_of? Array
                      obj.fetch('outputSource', [])
                    else
                      [obj['outputSource']]
                    end
    @linkMerge = if obj.include? 'linkMerge'
                   LinkMergeMethod.load(obj['linkMerge'])
                 else
                   LinkMergeMethod.load('merge_nested')
                 end
    @type = if obj.include? 'type'
              CWLOutputType.load(obj['type'])
            end
  end

  def to_h
    ret = {}
    ret['id'] = @id

    unless @label.nil?
      ret['label'] = @label
    end

    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |s|
        s.to_h
      }
    end

    if @streamable
      ret['streamable'] = @streamable
    end

    unless @doc.nil?
      ret['doc'] = @doc
    end

    unless @outputBinding.nil?
      ret['outputBinding'] = @outputBinding.to_h
    end

    unless @format.nil?
      ret['format'] = @format.to_h
    end

    unless @outputSource.empty?
      ret['outputSource'] = @outputSource
    end

    unless @linkMerge != 'merge_nested'
      ret['linkMerge'] = @linkMerge
    end

    unless @type.nil?
      ret['type'] = @type.to_h
    end

    ret
  end
end

class LinkMergeMethod
  def self.load(obj)
    case obj
    when 'merge_nested', 'merge_flattened'
      obj
    else
      raise CWLInspectionError, "Invalid LinkMergeMethod: #{obj}"
    end
  end
end

class OutputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = obj.fetch('fields', []).map{ |f|
      OutputRecordField.load(f)
    }
    @label = obj.fetch('label', nil)
  end

  def to_h
    ret = {}
    ret['type'] = @type
    unless @fields.empty?
      ret['fields'] = @fields.map{ |f|
        f.to_h
      }
    end
    ret['label'] = @label unless @label.nil?
    ret
  end
end

class OutputRecordField < CWLObject
  cwl_object_preamble :name, :type, :doc, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('name') and
      obj.include?('type')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLOutputType.load(obj['type'])
    @doc = obj.fetch('doc', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
  end

  def to_h
    ret = {}
    ret['name'] = @name
    ret['type'] = @type.to_h
    ret['doc'] = @doc unless @doc.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret
  end
end

class OutputEnumSchema < CWLObject
  cwl_object_preamble :symbols, :type, :label, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('symbols') and
      obj.include?('type')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
  end

  def to_h
    ret = {}
    ret['symbols'] = @symbols
    ret['type'] = @type
    unless @label.nil?
      ret['label'] = @label
    end
    unless @outputBinding.nil?
      ret['outputBinding'] = @outputBinding.to_h
    end
    ret
  end
end

class OutputArraySchema < CWLObject
  cwl_object_preamble :items, :type, :label, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('items') and
      obj.include?('type')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @items = CWLOutputType.load(obj['items'])
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
  end

  def to_h
    ret = {}
    ret['items'] = @items.to_h
    ret['type'] = @type
    unless @label.nil?
      ret['label'] = @label
    end
    unless @outputBinding.nil?
      ret['outputBinding'] = @outputBinding.to_h
    end
  end
end

class WorkflowStep < CWLObject
  cwl_object_preamble :id, :in, :out, :run, :requirements,
                      :hints, :label, :doc, :scatter, :scatterMethod

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id') and
      obj.include?('in') and
      obj.include?('out') and
      obj.include?('run')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @in = if obj['in'].instance_of? Array
            obj['in'].map{ |o|
              WorkflowStepInput.load(o)
            }
          else
            obj['in'].map{ |k, v|
              o = if v.instance_of? String or
                    v.instance_of? Array
                    {
                      'id' => k,
                      'source' => v,
                    }
                  else
                    o = {}
                    o['id'] = k
                    v.each{ |f, val|
                      o[f] = val
                    }
                    o
                  end
              WorkflowStepInput.load(o)
            }
          end
    @out = obj['out'].map{ |o|
      if o.instance_of? String
        WorkflowStepInput.load({ 'id' => o,})
      else
        WorkflowStepOutput.load(o)
      end
    }
    @run = if obj['run'].instance_of? String
             obj['run']
           else
             CommonWorkflowLanguage.load(obj['run'])
           end
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               o = {}
               o['class'] = k
               v.each{ |f, val|
                 o[f] = val
               }
               o
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                o = {}
                o['class'] = k
                v.each{ |f, val|
                  o[f] = val
                }
                o
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h)
    }

    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @scatter = if obj.fetch('scatter', []).instance_of? Array
                 obj.fetch('scatter', [])
               else
                 [obj['scatter']]
               end
    @scatterMethod = if obj.include? 'scatterMethod'
                       ScatterMethod.load(obj['scatterMethod'])
                     end
  end

  def self.load_requirement(req)
    unless req.include? 'class'
      raise CWLParseError, 'Invalid requriment object'
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req)
    when 'DockerRequirement'
      DockerRequirement.load(req)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req)
    when 'ResourceRequirement'
      ResourceRequirement.load(req)
    when 'SubworkflowFeatureRequirement'
      SubworkflowFeatureRequirement.load(req)
    when 'ScatterFeatureRequirement'
      ScatterFeatureRequirement.load(req)
    when 'MultipleInputFeatureRequirement'
      MultipleInputFeatureRequirement.load(req)
    when 'StepInputExpressionRequirement'
      StepInputExpressionRequirement.load(req)
    else
      raise CWLParseError, "Invalid requirement: #{req['class']}"
    end
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['in'] = @in.map{ |i|
      i.to_h
    }
    ret['out'] = @out.map{ |o|
      o.to_h
    }
    ret['run'] = @run.to_h
    unless @requirements.empty?
      ret['requirements'] = @requirements.map{ |r|
        r.to_h
      }
    end
    unless @hints.empty?
      ret['hints'] = @hints.map{ |h|
        h.to_i
      }
    end
    unless @label.nil?
      ret['label'] = @label
    end
    unless @doc.nil?
      ret['doc'] = @doc
    end
    unless @scatter.empty?
      ret['scatter'] = @scatter
    end
    unless @scatterMethod.nil?
      ret['scatterMethod'] = @scatterMethod
    end
    ret
  end
end

class WorkflowStepInput < CWLObject
  cwl_object_preamble :id, :source, :linkMerge, :default, :valueFrom

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @source = if obj.fetch('source', []).instance_of? Array
                obj.fetch('source', [])
              else
                [obj['source']]
              end
    @linkMerge = if obj.include? 'linkMerge'
                   LinkMergeMethod.load(obj['linkMerge'])
                 else
                   LinkMergeMethod.load('merge_nested')
                 end
    @default = if obj.include? 'default'
                 InputParameter.parse_object(nil, obj['default'])
               end
    @valueFrom = if obj.include? 'valueFrom'
                   Expression.load(obj['valueFrom'])
                 end
  end

  def to_h
    ret = {}
    ret['id'] = @id
    unless @source.empty?
      ret['source'] = @source
    end
    unless @linkMerge == 'merge_nested'
      ret['linkMerge'] = @linkMerge
    end
    unless @default.nil?
      ret['default'] = @default
    end
    unless @valueFrom.nil?
      ret['valueFrom'] = @valueFrom.to_h
    end
    ret
  end
end

class WorkflowStepOutput < CWLObject
  cwl_object_preamble :id

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @id = obj['id']
  end

  def to_h
    {
      'id' => @id,
    }
  end
end

class ScatterMethod
  def self.load(obj)
    case obj
    when 'dotproduct', 'nested_crossproduct', 'flat_crossproduct'
      obj
    else
      raise CWLParseError, "Unsupported scatter method: #{obj}"
    end
  end
end

class SubworkflowFeatureRequirement < CWLObject
  cwl_object_preamble :class_

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'SubworkflowFeatureRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def to_h
    {
      'class' => @class_,
    }
  end
end

class ScatterFeatureRequirement < CWLObject
  cwl_object_preamble :class_

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'ScatterFeatureRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def to_h
    {
      'class' => @class_,
    }
  end
end

class MultipleInputFeatureRequirement < CWLObject
  cwl_object_preamble :class_

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'MultipleInputFeatureRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def to_h
    {
      'class' => @class_,
    }
  end
end

class StepInputExpressionRequirement < CWLObject
  cwl_object_preamble :class_

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'StepInputExpressionRequirement'
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def to_h
    {
      'class' => @class_,
    }
  end
end

class ExpressionTool < CWLObject
  cwl_object_preamble :inputs, :outputs, :class_, :expression,
                      :id, :requirements, :hints, :label,
                      :doc, :cwlVersion

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('inputs') and
      obj.include?('outputs') and
      obj.fetch('class', '') == 'ExpressionTool' and
      obj.include?('expression')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @inputs = if obj['inputs'].instance_of? Array
                obj['inputs'].map{ |o|
                  InputParameter.load(o)
                }
              else
                obj['inputs'].map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'id' => k,
                          'type' => v,
                        }
                      else
                        o = {}
                        o['id'] = k
                        v.each{ |f, val|
                          o[f] = val
                        }
                        o
                      end
                  InputParameter.load(o)
                }
              end
    @outputs = if obj['outputs'].instance_of? Array
                obj['outputs'].map{ |o|
                  ExpressionToolOutputParameter.load(o)
                }
              else
                obj['outputs'].map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'id' => k,
                          'type' => v,
                        }
                      else
                        o = {}
                        o['id'] = k
                        v.each{ |f, val|
                          o[f] = val
                        }
                        o
                      end
                  ExpressionToolOutputParameter.load(o)
                }
               end
    @class_ = obj['class']
    @expression = Expression.load(obj['expression'])
    @id = obj.fetch('id', nil)
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               o = {}
               o['class'] = k
               v.each{ |f, val|
                 o[f] = val
               }
               o
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                o = {}
                o['class'] = k
                v.each{ |f, val|
                  o[f] = val
                }
                o
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h)
    }
    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @cwlVersion = obj.fetch('cwlVersion', nil)
  end

  def self.load_requirement(req)
    unless req.include? 'class'
      raise CWLParseError, 'Invalid requriment object'
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req)
    when 'DockerRequirement'
      DockerRequirement.load(req)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req)
    when 'ResourceRequirement'
      ResourceRequirement.load(req)
    when 'SubworkflowFeatureRequirement'
      SubworkflowFeatureRequirement.load(req)
    when 'ScatterFeatureRequirement'
      ScatterFeatureRequirement.load(req)
    when 'MultipleInputFeatureRequirement'
      MultipleInputFeatureRequirement.load(req)
    when 'StepInputExpressionRequirement'
      StepInputExpressionRequirement.load(req)
    else
      raise CWLParseError, "Invalid requirement: #{req['class']}"
    end
  end

  def to_h
    ret = {}
    ret['inputs'] = @inputs.map{ |inp|
      inp.to_h
    }
    ret['outputs'] = @outputs.map{ |out|
      out.to_h
    }
    ret['class'] = @class_
    ret['expression'] = @expression.to_h
    unless @id.nil?
      ret['id'] = @id
    end
    unless @requirements.empty?
      ret['requirements'] = @requirements.map{ |r|
        r.to_h
      }
    end
    unless @hints.empty?
      ret['hints'] = @hints.map{ |h|
        h.to_h
      }
    end
    unless @label.nil?
      ret['label'] = @label
    end
    unless @doc.nil?
      ret['doc'] = @doc
    end
    unless @cwlVersion.nil?
      ret['cwlVersion'] = @cwlVersion
    end
    ret
  end
end

class InputParameter < CWLObject
  cwl_object_preamble :id, :label, :secondaryFiles, :streamable,
                      :doc, :format, :inputBinding, :default, :type

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'])]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @format = if obj.fetch('format', []).instance_of? Array
                obj.fetch('format', []).map{ |f|
                  Expression.load(f)
                }
              else
                [Expression.load(obj['format'])]
              end
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'])
                    end
    @type = if obj.include? 'type'
              CWLInputType.load(obj['type'])
            end
    @default = if obj.include? 'default'
                 if @type.nil?
                   raise CWLParseError, 'Unsupported format: `default` without `type`'
                 end
                 InputParameter.parse_object(@type, obj['default'])
               end
  end

  def to_h
    ret = {}
    ret['id'] = @id
    unless @label.nil?
      ret['label'] = @label
    end
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |s|
        s.to_h
      }
    end
    if @streamable
      ret['streamable'] = @streamable
    end
    unless @doc.nil?
      ret['doc'] = @doc
    end
    unless @format.empty?
      ret['format'] = @format.map{ |f| f.to_h }
    end
    unless @inputBinding.nil?
      ret['inputBinding'] = @inputBinding.to_h
    end
    unless @default.nil?
      ret['default'] = @default.to_h
    end
    unless @type.nil?
      ret['type'] = @type.to_h
    end
    ret
  end
end

class ExpressionToolOutputParameter < CWLObject
  cwl_object_preamble :id, :label, :secondaryFiles, :streamable,
                      :doc, :format, :type

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id')
  end

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    unless self.class.valid?(obj)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = obj['id']
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'])]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'])
                     end
    @format = if obj.include? 'format'
                Expression.load(obj['format'])
              end
    @type = if obj.include? 'type'
              CWLOutputType.load(obj['type'])
            end
  end

  def to_h
    ret = {}
    ret['id'] = @id
    unless @label.nil?
      ret['label'] = @label
    end
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |s|
        s.to_h
      }
    end
    if @streamable
      ret['streamable'] = @streamable
    end
    unless @doc.nil?
      ret['doc'] = @doc
    end
    unless @outputBinding.nil?
      ret['outputBinding'] = @outputBinding.to_h
    end
    unless @format.nil?
      ret['format'] = @format.to_h
    end
    unless @type.nil?
      ret['type'] = @type
    end
    ret
  end
end

class InputParameter
  def self.parse_object(type, obj)
    if type.nil?
      type = guess_type(obj)
    end

    case type
    when CWLType
      case type.type
      when 'null'
        unless obj.nil?
          raise CWLParseError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'boolean'
        unless obj == true or obj == false
          raise CWLParseError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'int', 'long'
        unless obj.instance_of? Integer
          raise CWLParseError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'float', 'double'
        unless obj.instance_of? Float
          raise CWLParseError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'string'
        unless obj.instance_of? String
          raise CWLParseError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'File'
        CWLFile.load(obj)
      when 'Directory'
        Directory.load(obj)
      end
    when CommandInputRecordSchema
      raise CWLParseError, "Unsupported type: #{type.class}"
    when CommandInputArraySchema
      t = type.items
      unless obj.instance_of? Array
        raise CWLInspectionError, "Invalid value: array of #{t} is expected"
      end
      obj.map{ |o|
        self.parse_object(t, obj)
      }
    when CommandInputUnionSchema
      idx = type.types.find_index{ |ty|
        begin
          self.parse_object(ty, obj)
          true
        rescue CWLInspectionError
          false
        end
      }
      if idx.nil?
        raise CWLParseError, "Invalid object: #{obj}"
      end
      CWLUnionValue.new(type.types[idx],
                        self.parse_object(type.types[idx], obj))
    end
  end
end

class CWLUnionValue
  attr_accessor :type, :value

  def initialize(type, value)
    @type = type
    @value = value
  end

  def to_h
    @value.to_h
  end
end

def guess_type(value)
  case value
  when nil
    CWLType.load('null')
  when TrueClass, FalseClass
    CWLType.load('boolean')
  when Integer
    CWLType.load('int')
  when Float
    CWLType.load('float')
  when String
    CWLType.load('string')
  when Hash
    case value.fetch('class', nil)
    when 'File'
      CWLType.load('File')
    when 'Direcotry'
      CWLType.load('Directory')
    else
      raise CWLInspectionError, "Unsupported value: #{value}"
    end
  when Array
    CommandInputArraySchema.load({
                                   'type' => 'array',
                                   'items' => guess_type(value.first).to_h,
                                 })
  else
    raise CWLInspectionError, "Unsupported value: #{value}"
  end
end

if $0 == __FILE__
  format = :yaml
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} [options] cwl"
  opt.on('-j', '--json', 'Print CWL in JSON format') {
    format = :json
  }
  opt.on('-y', '--yaml', 'Print CWL in YAML format (default)') {
    format = :yaml
  }
  opt.parse!(ARGV)
  unless ARGV.length == 1
    puts opt.help
    exit
  end

  h = CommonWorkflowLanguage.load_file(ARGV.first).to_h
  if format == :yaml
    puts YAML.dump(h)
  else
    puts JSON.pretty_generate(h)
  end
end
