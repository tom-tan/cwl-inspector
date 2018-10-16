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
require_relative 'js-parser'
require_relative 'schema-salad'

class CWLParseError < Exception
end

class CWLInspectionError < Exception
end

class UnsupportedError < Exception
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

  def to_h
    nil
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

class Symbol
  def walk(path)
    if path.empty?
      return self
    else
      raise CWLInspectionError, "No such field for #{self}: #{path}"
    end
  end

  def to_h
    self.to_s
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
    if self.empty?
      self
    else
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
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self.map{ |e|
      e.evaluate(js_req, inputs, runtime, self_)
    }
  end

  def to_h
    self.map{ |e|
      e.to_h
    }
  end
end

def trim(id)
  if id.match(%r!^#.+/(.+)$!)
    $1
  else
    id
  end
end

def trim_source(id)
  if id.match(%r!^#[^/]+/(.+)$!)
    $1
  else
    id
  end
end

class CommonWorkflowLanguage
  def self.load_file(file, do_preprocess = true)
    obj = if do_preprocess
            preprocess(file)
          else
            YAML.load_file(file.sub(/#.*/, ''))
          end
    frags = fragments(obj)
    nss = namespaces(obj)
    obj = if file.match(/^.+#(.+)$/)
            frags[$1]
          else
            obj
          end
    self.load(obj, File.dirname(File.expand_path(file)), frags, nss)
  end

  def self.load(obj, dir, frags, nss)
    case obj.fetch('class', '')
    when 'CommandLineTool'
      CommandLineTool.load(obj, dir, frags, nss)
    when 'Workflow'
      Workflow.load(obj, dir, frags, nss)
    when 'ExpressionTool'
      ExpressionTool.load(obj, dir, frags, nss)
    else
      raise CWLParseError, "Cannot parse as #{self}"
    end
  end
end

class CWLObject
  attr_accessor :extras

  def self.inherited(subclass)
    subclass.class_eval{
      def subclass.cwl_object_preamble(*fields)
        class_variable_set(:@@fields, fields)
        attr_accessor(*fields)
      end

      def subclass.valid?(obj, nss)
        ns_fields, fields = obj.keys.partition{ |k| k.include? ':' }
        ns_fields.all?{ |nf|
          ns = nf.match(/^(.+):/)[1]
          nss.include? ns
        }

        fields.all?{ |k|
          class_variable_get(:@@fields).map{ |m|
            case m
            when :class_ then :class
            when :mixin then '$mixin'
            when :namespaces then '$namespaces'
            when :schemas then '$schemas'
            else m
            end
          }.any?{ |f|
            f.to_s == k
          } or k.start_with?('$')
        } and satisfies_additional_constraints(obj)
      end
    }
  end

  def self.contains_extensions(obj)
    keys = obj.keys
    keys.include?('$namespaces') or keys.include?('$schemas')
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

  def evaluate(js_req, inputs, runtime, self_ = nil)
    raise 'Unimplemented'
  end

  def keys
    to_h.keys
  end
end

class CommandLineTool < CWLObject
  cwl_object_preamble :inputs, :outputs, :class_, :id, :requirements,
                      :hints, :label, :doc, :cwlVersion, :baseCommand,
                      :arguments, :stdin, :stderr, :stdout, :successCodes,
                      :temporaryFailCodes, :permanentFailCodes, :namespaces, :schemas

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      ['inputs', 'outputs', 'class'].all?{ |f| obj.include? f } and
      obj['class'] == 'CommandLineTool'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @inputs = if obj['inputs'].instance_of? Array
                obj['inputs'].map{ |o|
                  CommandInputParameter.load(o, dir, frags, nss)
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
                        v.merge({ 'id' => k })
                      end
                  CommandInputParameter.load(o, dir, frags, nss)
                }
              end

    @outputs = if obj['outputs'].instance_of? Array
                 obj['outputs'].map{ |o|
                   CommandOutputParameter.load(o, dir, frags, nss)
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
                         v.merge({ 'id' => k })
                       end
                   CommandOutputParameter.load(o, dir, frags, nss)
                 }
               end

    @class_ = obj['class']
    @id = obj.fetch('id', nil)
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               v.merge({ 'class' => k })
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r, dir, frags, nss)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                v.merge({ 'class' => k })
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h, dir, frags, nss, true)
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
        CommandLineBinding.load(arg, dir, frags, nss)
      else
        CommandLineBinding.load({ 'valueFrom' => arg, }, dir, frags, nss)
      end
    }
    @stdin = obj.include?('stdin') ? Expression.load(obj['stdin'], dir, frags, nss) : nil
    @stderr = if obj.include?('stderr')
                Expression.load(obj['stderr'], dir, frags, nss)
              elsif @outputs.index{ |o| o.type.instance_of? Stderr }
                Expression.load(SecureRandom.alphanumeric+'.stderr', dir, frags, nss)
              else
                nil
              end
    @stdout = if obj.include?('stdout')
                Expression.load(obj['stdout'], dir, frags, nss)
              elsif @outputs.index{ |o| o.type.instance_of? Stdout }
                Expression.load(SecureRandom.alphanumeric+'.stdout', dir, frags, nss)
              else
                nil
              end
    @successCodes = obj.fetch('successCodes', [0])
    @temporaryFailCodes = obj.fetch('temporaryFailCodes', [])
    @permanentFailCodes = obj.fetch('permanentFailCodes', [])
    @namespaces = obj.fetch('$namespaces', nil)
    @schemas = obj.fetch('$schemas', nil)
  end

  def self.load_requirement(req, dir, frags, nss, hints = false)
    unless req.include? 'class'
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, 'Invalid requriment object'
      end
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req, dir, frags, nss)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req, dir, frags, nss)
    when 'DockerRequirement'
      DockerRequirement.load(req, dir, frags, nss)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req, dir, frags, nss)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req, dir, frags, nss)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req, dir, frags, nss)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req, dir, frags, nss)
    when 'ResourceRequirement'
      ResourceRequirement.load(req, dir, frags, nss)
    else
      if hints
        UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, "Invalid requirement: #{req['class']}"
      end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.inputs = @inputs.map{ |inp|
      inp.evaluate(js_req, inputs, runtime, inputs[inp.id])
    }
    ret.outputs = @outputs.map{ |out|
      out.evaluate(js_req, inputs, runtime, self_)
    }
    ret.requirements = @requirements.map{ |req|
      req.evaluate(js_req, inputs, runtime, self_)
    }
    ret.hints = @hints.map{ |h|
      h.evaluate(js_req, inputs, runtime, self_)
    }
    ret.arguments = @arguments.map{ |ar|
      ar.evaluate(js_req, inputs, runtime, self_)
    }
    ret.stdin = @stdin.evaluate(js_req, inputs, runtime, self_) unless @stdin.nil?
    ret.stderr = @stderr.evaluate(js_req, inputs, runtime, self_) unless @stderr.nil?
    ret.stdout = @stdout.evaluate(js_req, inputs, runtime, self_) unless @stdout.nil?
    ret
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
    ret['id'] = @id unless @id.nil?

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
    ret['$namespaces'] = @namespaces unless @namespaces.nil?
    ret['$schemas'] = @schemas unless @schemas.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          if sec.include?('$(') or sec.include?('${')
                            Expression.load(sec, dir, frags, nss)
                          else
                            sec
                          end
                        }
                      else
                        sec = obj['secondaryFiles']
                        if sec.include?('$(') or sec.include?('${')
                          [Expression.load(sec, dir, frags, nss)]
                        else
                          [sec]
                        end
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @format = if obj.fetch('format', []).instance_of? Array
                obj.fetch('format', []).map{ |f|
                  fexp = if f.match(%r!^(.+):[^/]!)
                           ns = $1
                           unless nss.include? ns
                             raise CWLParseError, "No such namespace: #{ns}"
                           end
                           f.sub(/^#{ns}:/, nss[ns])
                         else
                           f
                         end
                  Expression.load(fexp, dir, frags, nss)
                }
              else
                f = obj['format']
                fexp = if f.match(%r!^(.+):[^/]!)
                         ns = $1
                         unless nss.include? ns
                           raise CWLParseError, "No such namespace: #{ns}"
                         end
                         f.sub(/^#{ns}:/, nss[ns])
                       else
                         f
                       end
                [Expression.load(fexp, dir, frags, nss)]
              end
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
    @type = if obj.include? 'type'
              CWLCommandInputType.load(obj['type'], dir, frags, nss)
            end
    @default = if obj.include? 'default'
                 if @type.nil?
                   raise CWLParseError, 'Unsupported syntax: `default` without `type`'
                 end
                 InputParameter.parse_object(@type, obj['default'], dir, frags, nss)
               end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.secondaryFiles = @secondaryFiles.map{ |sec|
      sec.evaluate(js_req, inputs, runtime, self_)
    }
    ret.format = @format.map{ |f|
      f.evaluate(js_req, inputs, runtime, self_)
    }
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret.type = @type.evaluate(js_req, inputs, runtime, self_) unless @type.nil?
    ret
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
    ret['doc'] = @doc unless @doc.nil? or @doc.empty?
    unless @format.empty?
      ret['format'] = @format.map{ |f|
        f.to_h
      }
    end
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret['default'] = @default.to_h unless @default.nil?
    ret['type'] = @type.to_h unless @type.nil?
    ret
  end
end

class CommandLineBinding < CWLObject
  cwl_object_preamble :loadContents, :position, :prefix, :separate,
                      :itemSeparator, :valueFrom, :shellQuote

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @loadContents = obj.fetch('loadContents', false)
    @position = obj.fetch('position', 0)
    @prefix = obj.fetch('prefix', nil)
    @separate = obj.fetch('separate', true)
    @itemSeparator = obj.fetch('itemSeparator', nil)
    @valueFrom = if obj.include? 'valueFrom'
                   Expression.load(obj['valueFrom'], dir, frags, nss)
                 end
    @shellQuote = obj.fetch('shellQuote', true)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.valueFrom = @valueFrom.evaluate(js_req, inputs, runtime, self_) unless @valueFrom.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
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

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    @type
  end
end

class CWLInputType
  def self.load(obj, dir, frags, nss)
    case obj
    when Array
      InputUnionSchema.load(obj, dir, frags, nss)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        InputRecordSchema.load(obj, dir, frags, nss)
      when 'enum'
        InputEnumSchema.load(obj, dir, frags, nss)
      when 'array'
        InputArraySchema.load(obj, dir, frags, nss)
      end
    when /^(.+)\?$/
      InputUnionSchema.load([$1, 'null'], dir, frags, nss)
    when /^(.+)\[\]$/
      InputArraySchema.load({
                              'type' => 'array',
                              'items' => $1,
                            }, dir, frags, nss)
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory', 'Any'
      CWLType.load(obj, dir, frags, nss)
    when /^(.+)#(.+)$/
      file, fragment = $1, $2
      self.load(fragments(File.join(dir, file))[fragment], dir, frags, nss)
    when /^#(.+)$/
      f = frags[$1]
      self.load(f, dir, frags, nss)
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end
end

class CWLCommandInputType
  def self.load(obj, dir, frags, nss)
    case obj
    when Array
      CommandInputUnionSchema.load(obj, dir, frags, nss)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        CommandInputRecordSchema.load(obj, dir, frags, nss)
      when 'enum'
        CommandInputEnumSchema.load(obj, dir, frags, nss)
      when 'array'
        CommandInputArraySchema.load(obj, dir, frags, nss)
      end
    when /^(.+)\?$/
      CommandInputUnionSchema.load([$1, 'null'], dir, frags, nss)
    when /^(.+)\[\]$/
      CommandInputArraySchema.load({
                                     'type' => 'array',
                                     'items' => $1,
                                   }, dir, frags, nss)
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory', 'Any'
      CWLType.load(obj, dir, frags, nss)
    when /^(.+)#(.+)$/
      file, fragment = $1, $2
      self.load(fragments(File.join(dir, file))[fragment], dir, frags, nss)
    when /^#(.+)$/
      self.load(frags[$1], dir, frags, nss)
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end
end

class CWLOutputType
  def self.load(obj, dir, frags, nss)
    case obj
    when Array
      OutputUnionSchema.load(obj, dir, frags, nss)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        OutputRecordSchema.load(obj, dir, frags, nss)
      when 'enum'
        OutputEnumSchema.load(obj, dir, frags, nss)
      when 'array'
        OutputArraySchema.load(obj, dir, frags, nss)
      end
    when /^(.+)\?$/
      OutputUnionSchema.load([$1, 'null'], dir, frags, nss)
    when /^(.+)\[\]$/
      OutputArraySchema.load({
                               'type' => 'array',
                               'items' => $1,
                             }, dir, frags, nss)
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory', 'Any'
      CWLType.load(obj, dir, frags, nss)
    else
      raise CWLParseError, "Unimplemented type: #{obj.to_h}"
    end
  end
end

class CWLCommandOutputType
  def self.load(obj, dir, frags, nss)
    case obj
    when Array
      CommandOutputUnionSchema.load(obj, dir, frags, nss)
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        CommandOutputRecordSchema.load(obj, dir, frags, nss)
      when 'enum'
        CommandOutputEnumSchema.load(obj, dir, frags, nss)
      when 'array'
        CommandOutputArraySchema.load(obj, dir, frags, nss)
      end
    when /^(.+)\?$/
      CommandOutputUnionSchema.load([$1, 'null'], dir, frags, nss)
    when /^(.+)\[\]$/
      CommandOutputArraySchema.load({
                                     'type' => 'array',
                                     'items' => $1,
                                   }, dir, frags, nss)
    when 'null', 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory', 'Any'
      CWLType.load(obj, dir, frags, nss)
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

  def self.load(obj, dir, frags, nss)
    file = self.new(obj, dir, frags, nss)
    file.evaluate(dir, false)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse #{obj} as #{self.class}"
    end
    @class_ = obj['class']
    @location = obj.fetch('location', nil)
    @path = obj.fetch('path', nil)
    @basename = obj.fetch('basename', nil)
    @dirname = nil
    @nameroot = nil
    @nameext = nil
    @checksum = nil
    @size = nil
    @secondaryFiles = obj.fetch('secondaryFiles', []).map{ |f|
      case f.fetch('class', '')
      when 'File'
        CWLFile.load(f, dir, frags, nss)
      when 'Directory'
        Directory.load(f, dir, frags, nss)
      else
        raise CWLParseError, "Cannot parse as #{self.class}"
      end
    }
    @format = if obj.include? 'format'
                f = obj['format']
                if f.match(%r!^(.+):[^/]!)
                  ns = $1
                  unless nss.include? ns
                    raise CWLParseError, "No such namespace: #{ns}"
                  end
                  f.sub(/^#{ns}:/, nss[ns])
                else
                  f
                end
              end
    @contents = obj.fetch('contents', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def evaluate(docdir, loadContents = false)
    file = self.dup
    location = @location.nil? ? @path : @location
    if location.nil?
      if @contents.nil?
        raise CWLInspectionError, "`path`, `location` or `contents` is necessary for File object: #{self}"
      end
    else
      file.location, file.path = case location
                                 when %r|^(.+:)//(.+)$|
                                   scheme, path = $1, $2
                                   case scheme
                                   when 'file:'
                                     [location, path]
                                   when 'http:', 'https:', 'ftp:'
                                     raise CWLInspectionError, "Unsupported scheme: #{scheme}"
                                   else
                                     raise CWLInspectionError, "Unsupported scheme: #{scheme}"
                                   end
                                 else
                                   path = File.expand_path(location, docdir)
                                   ['file://'+path, path]
                                 end
      file.dirname = File.dirname file.path
      file.nameext = File.extname file.path
      file.nameroot = File.basename file.path, file.nameext
      file.format = @format
      if File.exist? file.path
        digest = Digest::SHA1.hexdigest(File.open(file.path, 'rb').read)
        file.checksum = "sha1$#{digest}"
        file.size = File.size(file.path)
      end
    end

    file.basename = if file.basename
                      file.basename
                    elsif file.path
                      File.basename(file.path)
                    end
    file.secondaryFiles = @secondaryFiles.map{ |sf|
      # TODO: eval needs nss!
      sf.evaluate(docdir, loadContents)
    }
    file.contents = if @contents
                      @contents
                    elsif loadContents and File.exist?(file.path)
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

  def self.load(obj, dir, frags, nss)
    d = self.new(obj, dir, frags, nss)
    d.evaluate(dir, false)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    @location = obj.fetch('location', nil)
    @path = obj.fetch('path', nil)
    @basename = obj.fetch('basename', nil)
    @listing = obj.fetch('listing', []).map{ |f|
      case f.fetch('class', '')
      when 'File'
        CWLFile.load(f, dir, frags, nss)
      when 'Directory'
        Directory.load(f, dir, frags, nss)
      else
        raise CWLParseError, "Cannot parse as #{self.class}"
      end
    }
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def evaluate(docdir, loadContents = false)
    dir = self.dup
    location = @location.nil? ? @path : @location
    if @location.nil?
      if @listing.empty?
        raise CWLInspectionError, "`path`, `location` or `listing` fields is necessary for Directory object: #{self}"
      end
    end

    if location
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
                                 path = File.expand_path(location, docdir)
                                 ['file://'+path, path]
                               end
      dir.basename = if dir.basename
                       dir.basename
                     elsif dir.path
                       File.basename dir.path
                     end
      if Dir.exist? dir.path
        dir.listing = Dir.entries(dir.path).reject{ |lst| lst.match(/^\.+$/) }.map{ |lst|
          path = File.expand_path(lst, dir.path)
          if File.directory? path
            d = Directory.load({
                                 'class' => 'Directory',
                                 'location' => 'file://'+path,
                               }, docdir, {}, {}) # TODO: extras
            d.evaluate(docdir, false)
          else
            f = CWLFile.load({
                               'class' => 'File',
                               'location' => 'file://'+path,
                             }, docdir, {}, {}) # TODO: extras
            f.evaluate(docdir, false)
          end
        }
      end
    else
      dir.listing = @listing.map{ |lst|
        lst.evaluate(docdir, loadContents)
      }
    end
    dir
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
  attr_accessor :types

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless obj.instance_of? Array
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @types = obj.map{ |o|
      CWLCommandInputType.load(o, dir, frags, nss)
    }
  end

  def walk(path)
    @types.walk(path)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.types = @types.map{ |t|
      t.evaluate(js_req, inputs, runtime, self_)
    }
    ret
  end

  def to_h
    @types.map{ |t|
      t.to_h
    }
  end
end

class CommandInputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label, :name

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = if obj.fetch('fields', []).instance_of? Array
                obj.fetch('fields', []).map{ |f|
                  CommandInputRecordField.load(f, dir, frags, nss)
                }
              else
                obj.map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'name' => k,
                          'type' => v,
                        }
                      else
                        v.merge({ 'name' => k })
                      end
                  CommandInputRecordField.load(o, dir, frags, nss)
                }
              end
    @label = obj.fetch('label', nil)
    @name = obj.fetch('name', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.fields = @fields.map{ |f|
      f.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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
    ret['name'] = @name unless @name.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLCommandInputType.load(obj['type'], dir, frags, nss)
    @doc = obj.fetch('doc', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
    @label = obj.fetch('label', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.type = @type.evaluate(js_req, inputs, runtime, self_)
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret
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
  cwl_object_preamble :symbols, :type, :label, :name, :inputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('symbols') and
      obj.fetch('type', '') == 'enum'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}: #{obj.to_h}"
    end
    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @items = CWLCommandInputType.load(obj['items'], dir, frags, nss)
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.items = @items.evaluate(js_req, inputs, runtime, self_)
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          if sec.include?('$(') or sec.include?('${')
                            Expression.load(sec, dir, frags, nss)
                          else
                            sec
                          end
                        }
                      else
                        sec = obj['secondaryFiles']
                        if sec.include?('$(') or sec.include?('${')
                          [Expression.load(sec, dir, frags, nss)]
                        else
                          [sec]
                        end
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
    @format = if obj.include? 'format'
                f = obj['format']
                case f
                when %r!^(.+):[^/]!
                  ns = $1
                  unless nss.include? ns
                    raise CWLParseError, "No such namespace: #{ns}"
                  end
                  Expression.load(f.sub(/^#{ns}:/, nss[ns]), dir, frags, nss)
                else
                  Expression.load(f, dir, frags, nss)
                end
              end
    @type = if obj.include? 'type'
              case obj['type']
              when 'stdout'
                Stdout.load(obj['type'], dir, frags, nss)
              when 'stderr'
                Stderr.load(obj['type'], dir, frags, nss)
              else
                CWLCommandOutputType.load(obj['type'], dir, frags, nss)
              end
            end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.secondaryFiles = @secondaryFiles.map{ |sec|
      sec.evaluate(js_req, inputs, runtime, self_)
    }
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret.format = @format.evaluate(js_req, inputs, runtime, self_) unless @format.nil?
    ret.type = @type.evaluate(js_req, inputs, runtime, self_) unless @type.nil?
    ret
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
    ret['format'] = @format.to_h unless @format.nil?
    ret['type'] = @type.to_h unless @type.nil?
    ret
  end
end

class Stdout
  def self.load(obj, dir, frags, nss)
    self.new
  end

  def walk(path)
    if path.empty?
      'stdout'
    else
      raise CWLParseError, "No such field for stdout: #{path}"
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    'stdout'
  end
end

class Stderr
  def self.load(obj, dir, frags, nss)
    self.new
  end

  def walk(path)
    if path.empty?
      'stderr'
    else
      raise CWLParseError, "No such field for stderr: #{path}"
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    'stderr'
  end
end

class CommandOutputBinding < CWLObject
  cwl_object_preamble :glob, :loadContents, :outputEval

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @glob = if obj.fetch('glob', []).instance_of? Array
              obj.fetch('glob', []).map{ |g|
                Expression.load(g, dir, frags, nss)
              }
            else
              [Expression.load(obj['glob'], dir, frags, nss)]
            end

    @loadContents = obj.fetch('loadContents', false)
    @outputEval = if obj.include? 'outputEval'
                    Expression.load(obj['outputEval'], dir, frags, nss)
                  end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.glob = @glob.map{ |g|
      g.evaluate(js_req, inputs, runtime, self_)
    }
    ret.outputEval = @outputEval.evaluate(js_req, inputs, runtime, self_) unless @outputEval.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless obj.instance_of? Array
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @types = obj.map{ |o|
      CWLCommandOutputType.load(o, dir, frags, nss)
    }
  end

  def walk(path)
    @types.walk(path)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.types = @types.map{ |t|
      t.evaluate(js_req, inputs, runtime, self_)
    }
    ret
  end

  def to_h
    @types.map{ |t|
      t.to_h
    }
  end
end

class CommandOutputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label, :name

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = if obj.fetch('fields', []).instance_of? Array
                obj.fetch('fields', []).map{ |f|
                  CommandOutputRecordField.load(f, dir, frags, nss)
                }
              else
                obj.map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'name' => k,
                          'type' => v,
                        }
                      else
                        v.merge({ 'name' => k })
                      end
                  CommandOutputRecordField.load(o, dir, frags, nss)
                }
              end
    @label = obj.fetch('label', nil)
    @name = obj.fetch('name', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.fields = @fields.map{ |f|
      f.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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
    ret['name'] = @name unless @name.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLCommandOutputType.load(obj['type'], dir, frags, nss)
    @doc = obj.fetch('doc', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.type = @type.evaluate(js_req, inputs, runtime, self_)
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags)
                     end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @items = CWLCommandOutputType.load(obj['items'], dir, frags, nss)
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.items = @items.evaluate(js_req, inputs, runtime, self_)
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret
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
  cwl_object_preamble :class_, :expressionLib, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', 'InlineJavascriptRequirement')
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @expressionLib = obj.fetch('expressionLib', [])
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
      unless @expressionLib.empty?
        ret['expressionLib'] = @expressionLib
      end
    else
      ret['$mixin'] = @mixin
    end
    ret
  end
end

class SchemaDefRequirement < CWLObject
  cwl_object_preamble :class_, :types, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', 'SchemaDefRequirement') and
      (obj.include?('$mixin') or obj.include?('types'))
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @types = obj['types'].map{ |t|
        self.class.load_input_type(t, dir, frags, nss)
      }
    end
  end

  def self.load_input_type(obj, dir, frags, nss)
    unless obj.instance_of?(Hash) and
          obj.include? 'type'
      raise CWLParseError, 'Invalid type object: #{obj}'
    end

    case obj['type']
    when 'record'
      InputRecordSchema.load(obj, dir, frags, nss)
    when 'enum'
      InputEnumSchema.load(obj, dir, frags, nss)
    when 'array'
      InputArraySchema.load(obj, dir, frags, nss)
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.types = @types.map{ |t|
      t.evaluate(js_req, inputs, runtime, self_)
    }
    ret
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
      ret['types'] = @types.map{ |t|
        t.to_h
      }
    else
      ret['$mixin'] = @mixin
    end
    ret
  end
end

class InputUnionSchema < CWLObject
  attr_reader :types

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless obj.instance_of? Array
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @types = obj.map{ |o|
      CWLInputType.load(o, dir, frags, nss)
    }
  end

  def walk(path)
    @types.walk(path)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.types = @types.map{ |t|
      t.evaluate(js_req, inputs, runtime, self_)
    }
    ret
  end

  def to_h
    @types.map{ |t|
      t.to_h
    }
  end
end

class InputRecordSchema < CWLObject
  cwl_object_preamble :type, :fields, :label, :name

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('type', '') == 'record'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = if obj.fetch('fields', []).instance_of? Array
                obj.fetch('fields', []).map{ |f|
                  InputRecordField.load(f, dir, frags, nss)
                }
              else
                obj.map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'name' => k,
                          'type' => v,
                        }
                      else
                        v.merge({ 'name' => k })
                      end
                  InputRecordField.load(o, dir, frags, nss)
                }
              end
    @label = obj.fetch('label', nil)
    @name = obj.fetch('name', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.fields = @fields.map{ |f|
      f.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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
    ret['name'] = @name unless @name.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLInputType.load(obj['type'], dir, frags, nss)
    @doc = obj.fetch('doc', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
    @label = obj.fetch('label', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.type = @type.evaluate(js_req, inputs, runtime, self_)
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret
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
  cwl_object_preamble :symbols, :type, :label, :name, :inputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('symbols') and
      obj.fetch('type', '') == 'enum'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @items = CWLInputType.load(obj['items'], dir, frags, nss)
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.items = @items.evaluate(js_req, inputs, runtime, self_)
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret
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
                      :dockerImport, :dockerImageId, :dockerOutputDirectory, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'DockerRequirement'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @dockerPull = obj.fetch('dockerPull', nil)
      @dockerLoad = obj.fetch('dockerLoad', nil)
      @dockerFile = obj.fetch('dockerFile', nil)
      @dockerImport = obj.fetch('dockerImport', nil)
      @dockerImageId = obj.fetch('dockerImageId', nil)
      @dockerOutputDirectory = obj.fetch('dockerOutputDirectory', nil)
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
      ret['dockerPull'] = @dockerPull unless @dockerPull.nil?
      ret['dockerLoad'] = @dockerLoad unless @dockerLoad.nil?
      ret['dockerFile'] = @dockerFile unless @dockerFile.nil?
      ret['dockerImport'] = @dockerImport unless @dockerImport.nil?
      ret['dockerImageId'] = @dockerImageId unless @dockerImageId.nil?
      ret['dockerOutputDirectory'] = @dockerOutputDirectory unless @dockerOutputDirectory.nil?
    else
      ret['$mixin'] = @mixin
    end
    ret
  end
end

class SoftwareRequirement < CWLObject
  cwl_object_preamble :class_, :packages, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'SoftwareRequirement' and
      (obj.include?('$mixin') or obj.include?('packages'))
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @packages = if obj['packages'].instance_of? Array
                    obj['packages'].map{ |p|
                      SoftwarePackage.load(p, dir, frags, nss)
                    }
                  else
                    ps = obj['packages']
                    packages = if ps.values.first.instance_of? Hash
                                 ps.map{ |k, v|
                                   v.merge({ 'package' => k })
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
                      SoftwarePackage.load(p, dir, frags, nss)
                    }
                  end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
      ret['packages'] = @packages.map{ |p|
        p.to_h
      }
    else
      ret['$mixin'] = @mixin
    end
    ret
  end
end

class SoftwarePackage < CWLObject
  cwl_object_preamble :package, :version, :specs

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include? 'package'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @package = obj['package']
    @version = obj.fetch('version', [])
    @specs = obj.fetch('specs', [])
  end

  def to_h
    ret = {}
    ret['package'] = @package
    ret['version'] = @version unless @version.empty?
    ret['specs'] = @specs unless @specs.empty?
    ret
  end
end

class InitialWorkDirRequirement < CWLObject
  cwl_object_preamble :class_, :listing, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'InitialWorkDirRequirement' and
      (obj.include?('$mixin') or obj.include?('listing'))
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @listing = if obj['listing'].instance_of? Array
                   obj['listing'].map{ |lst|
                     self.class.load_list(lst, dir, frags, nss)
                   }
                 else
                   [Expression.load(obj['listing'], dir, frags, nss)]
                 end
    end
  end

  def self.load_list(obj, dir, frags, nss)
    if obj.instance_of? String
      Expression.load(obj, dir, frags, nss)
    else
      case obj.fetch('class', 'Dirent')
      when 'File'
        CWLFile.load(obj, dir, frags, nss)
      when 'Directory'
        Directory.load(obj, dir, frags, nss)
      when 'Dirent'
        Dirent.load(obj, dir, frags, nss)
      end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.listing = @listing.map{ |lst|
      lst.evaluate(js_req, inputs, runtime, self_)
    }
    ret
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
      ret['listing'] = @listing.map{ |lst|
        lst.to_h
      }
    else
      ret['$mixin'] = @mixin
    end
    ret
  end
end

class Dirent < CWLObject
  cwl_object_preamble :entry, :entryname, :writable

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include? 'entry'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @entry = Expression.load(obj['entry'], dir, frags, nss)
    @entryname = if obj.include? 'entryname'
                   Expression.load(obj['entryname'], dir, frags, nss)
                 end
    @writable = obj.fetch('writable', false)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.entry = @entry.evaluate(js_req, inputs, runtime, self_)
    ret.entryname = @entryname.evaluate(js_req, inputs, runtime, self_) unless @entryname.nil?
    ret
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
  cwl_object_preamble :class_, :envDef, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'EnvVarRequirement' and
      (obj.include?('$mixin') or obj.include?('envDef'))
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @envDef = if obj['envDef'].instance_of? Array
                  obj['envDef'].map{ |env|
                    EnvironmentDef.load(env, dir, frags, nss)
                  }
                else
                  defs = obj['envDef']
                  if defs.values.first.instance_of? String
                    defs.map{ |k, v|
                      EnvironmentDef.load({
                                            'envName' => k,
                                            'envValue' => v,
                                          }, dir, frags, nss)
                    }
                  else
                    defs.map{ |k, v|
                      EnvironmentDef.load(v.merge({ 'envName' => k }),
                                          dir, frags, nss)
                    }
                  end
                end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.envDef = @envDef.map{ |e|
      e.evaluate(js_req, inputs, runtime, self_)
    }
    ret
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
      ret['envDef'] = @envDef.map{ |env|
        env.to_h
      }
    else
      ret['$mixin'] = @mixin
    end
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @envName = obj['envName']
    @envValue = Expression.load(obj['envValue'], dir, frags, nss)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.envValue = @envValue.evaluate(js_req, inputs, runtime, self_)
    ret
  end

  def to_h
    ret = {}
    ret['envName'] = @envName
    ret['envValue'] = @envValue.to_h
    ret
  end
end

class ShellCommandRequirement < CWLObject
  cwl_object_preamble :class_, :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'ShellCommandRequirement'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['$mixin'] = @mixin unless @mixin.nil?
    ret
  end
end

class ResourceRequirement < CWLObject
  cwl_object_preamble :class_, :coresMin, :coresMax, :ramMin, :ramMax,
                      :tmpdirMin, :tmpdirMax, :outdirMin, :outdirMax,
                      :mixin

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'ResourceRequirement'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
    if obj.include? '$mixin'
      @mixin = obj['$mixin']
    else
      @coresMin = if obj.include? 'coresMin'
                    if obj['coresMin'].instance_of? String
                      Expression.load(obj['coresMin'], dir, frags, nss)
                    else
                      obj['coresMin']
                    end
                  end
      @coresMax = if obj.include? 'coresMax'
                    if obj['coresMax'].instance_of? String
                      Expression.load(obj['coresMax'], dir, frags, nss)
                    else
                      obj['coresMax']
                    end
                  end
      @ramMin = if obj.include? 'ramMin'
                  if obj['ramMin'].instance_of? String
                    Expression.load(obj['ramMin'], dir, frags, nss)
                  else
                    obj['ramMin']
                  end
                end
      @ramMax = if obj.include? 'ramMax'
                  if obj['ramMax'].instance_of? String
                    Expression.load(obj['ramMax'], dir, frags, nss)
                  else
                    obj['ramMax']
                  end
                end
      @tmpdirMin = if obj.include? 'tmpdirMin'
                     if obj['tmpdirMin'].instance_of? String
                       Expression.load(obj['tmpdirMin'], dir, frags, nss)
                     else
                       obj['tmpdirMin']
                     end
                   end
      @tmpdirMax = if obj.include? 'tmpdirMax'
                     if obj['tmpdirMax'].instance_of? String
                       Expression.load(obj['tmpdirMax'], dir, frags, nss)
                     else
                       obj['tmpdirMax']
                     end
                   end
      @outdirMin = if obj.include? 'outdirMin'
                     if obj['outdirMin'].instance_of? String
                       Expression.load(obj['outdirMin'], dir, frags, nss)
                     else
                       obj['outdirMin']
                     end
                   end
      @outdirMax = if obj.include? 'outdirMax'
                     if obj['outdirMax'].instance_of? String
                       Expression.load(obj['outdirMax'], dir, frags, nss)
                     else
                       obj['outdirMax']
                     end
                   end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.coresMin = if @coresMin.instance_of? Expression
                     @coresMin.evaluate(js_req, inputs, runtime, self_)
                   else
                     @coresMin
                   end
    ret.coresMax = if @coresMax.instance_of? Expression
                     @coresMax.evaluate(js_req, inputs, runtime, self_)
                   else
                     @coresMax
                   end
    ret.ramMin = if @ramMin.instance_of? Expression
                   @ramMin.evaluate(js_req, inputs, runtime, self_)
                 else
                   @ramMin
                 end
    ret.ramMax = if @ramMax.instance_of? Expression
                   @ramMax.evaluate(js_req, inputs, runtime, self_)
                 else
                   @ramMax
                 end
    ret.tmpdirMin = if @tmpdirMin.instance_of? Expression
                      @tmpdirMin.evaluate(js_req, inputs, runtime, self_)
                    else
                      @tmpdirMin
                    end
    ret.tmpdirMax = if @tmpdirMax.instance_of? Expression
                      @tmpdirMax.evaluate(js_req, inputs, runtime, self_)
                    else
                      @tmpdirMax
                    end
    ret.outdirMin = if @outdirMin.instance_of? Expression
                      @outdirMin.evaluate(js_req, inputs, runtime, self_)
                    else
                      @outdirMin
                    end
    ret.outdirMax = if @outdirMax.instance_of? Expression
                      @outdirMax.evaluate(js_req, inputs, runtime, self_)
                    else
                      @outdirMax
                    end
    ret
  end

  def to_h
    ret = {}
    ret['class'] = @class_
    if @mixin.nil?
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
    else
      ret['$mixin'] = @mixin
    end
    ret
  end
end

def evaluate_parameter_reference(exp, inputs, runtime, self_)
  path = exp.split(/\.|\]\[|\[|\]\.?/).map{ |e|
    if e.start_with?("\'") or e.start_with?("\"")
      e[1...-1]
    else
      e
    end
  }.map{ |e|
    e.gsub(/\\'/, "'").gsub(/\\"/, "\"")
  }
  case path.first
  when 'inputs'
    if path[1..-1].empty?
      inputs
    else
      attr = path[1]
      unless inputs.include? attr
        raise CWLInspectionError, "Invalid parameter: inputs.#{attr}"
      end
      inputs[attr].walk(path[2..-1])
    end
  when 'self'
    if self_.nil?
      raise CWLInspectionError, "Unknown context for self in the expression: #{exp}"
    end
    if path[1..-1].empty?
      self_
    else
      self_.walk(path[1..-1])
    end
  when 'runtime'
    attr = path[1]
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

def escape(exp)
  exp.gsub(/\\/) { '\\\\' }.gsub(/"/, '\"').gsub(/\n/, '\n')
end

def evaluate_js_expression(js_req, expression, kind, inputs, runtime, self_)
  invalids = inputs.select{ |k, v|
    v.instance_of? InvalidVariable
  }
  unless invalids.empty?
    raise CWLInspectionError, "Invalid input parameter: #{invalids.keys.join(', ')}"
  end
  node = node_bin
  exps = js_req.expressionLib ? js_req.expressionLib : []
  e = if kind == :expression
        "(#{expression})"
      else
        "(function() { #{expression} })()"
      end
  exps.push e
  exp = escape(exps.join(";\n"))
  replaced_inputs = Hash[inputs.map{ |k, v|
                           [k, v.to_h]
                         }]
  cmdstr = <<-EOS
  'use strict'
  try{
    const exp = "#{exp}";
    process.stdout.write(JSON.stringify(require('vm').runInNewContext(exp, {
      'runtime': #{JSON.dump(runtime.reject{ |k, _| k == 'docdir' })},
      'inputs': #{JSON.dump(replaced_inputs)},
      'self': #{JSON.dump(self_.to_h)}
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
  ret
end

def parse_parameter_reference(str)
  symbol = /\w+/
  singleq = /\['([^']|\\')*'\]/
  doubleq = /\["([^"]|\\")*"\]/
  index = /\[\d+\]/
  segment = /\.#{symbol}|#{singleq}|#{doubleq}|#{index}/
  parameter_reference = /\$\((#{symbol}#{segment}*)\)/
  if str.match(parameter_reference)
    [$~.pre_match, $1, $~.post_match]
  else
    [str, '', '']
  end
end

def parse_js_expression(str)
  m = ECMAScriptExpressionParser.new.parse str
  exp = m[:body].to_s
  pre = m[:pre].instance_of?(Array) ? '' : m[:pre].to_s
  post = m[:post].instance_of?(Array) ? '' : m[:post].to_s
  [pre, exp, post]
end

def parse_js_funbody(str)
  m = ECMAScriptFunctionBodyParser.new.parse str
  exp = m[:body].to_s
  pre = m[:pre].instance_of?(Array) ? '' : m[:pre].to_s
  post = m[:post].instance_of?(Array) ? '' : m[:post].to_s
  [pre, exp, post]
end

class Expression
  attr_reader :expression

  def self.load(obj, dir, frags, nss)
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

  def evaluate(js_req, inputs, runtime, self_ = nil)
    unless inputs.values.find_index{ |v| v.instance_of? UninstantiatedVariable }.nil?
      return "evaled(#{@expression})"
    end
    expression = @expression

    rx = js_req ? /\$([({])/ : /\$\(/

    evaled = []
    only_exp = true
    while expression.match rx
      kind = $1 == '(' ? :expression : :body
      parser = if js_req
                 case kind
                 when :expression
                   lambda{ |e| parse_js_expression(e) }
                 when :body
                   lambda{ |e| parse_js_funbody(e) }
                 end
               else
                 lambda{ |e| parse_parameter_reference(e) }
               end
      begin
        pre, exp, post = parser.call(expression)
        ret = if js_req
                evaluate_js_expression(js_req, exp, kind, inputs, runtime, self_)
              else
                evaluate_parameter_reference(exp, inputs, runtime, self_)
              end
        if pre.empty?
          evaled.push ret
        else
          only_exp = false
          evaled.push(pre, ret)
        end
        expression = post
      rescue Parslet::ParseFailed
        str = js_req ? 'Javascript expression' : 'parameter reference'
        raise CWLInspectionError, "Invalid #{str}: #{expression}"
      end
    end
    if evaled.empty?
      expression
    else
      es = if expression.empty? or
             (only_exp and expression.end_with?("\n"))
             evaled
           else
             [*evaled, expression]
           end
      if es.length == 1
        InputParameter.parse_object(nil, es.first, runtime['docdir'].first, {}, {})
      else
        es.map{ |e|
          e.nil? ? 'null' : e
        }.join
      end
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

  def self.load(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self}"
    end
    obj
  end
end

class Workflow < CWLObject
  cwl_object_preamble :inputs, :outputs, :class_, :steps, :id, :requirements,
                      :hints, :label, :doc, :cwlVersion, :namespaces, :schemas

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      ['inputs', 'outputs', 'class', 'steps'].all?{ |f| obj.include? f } and
      obj['class'] == 'Workflow'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @inputs = if obj['inputs'].instance_of? Array
                obj['inputs'].map{ |o|
                  InputParameter.load(o, dir, frags, nss)
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
                        v.merge({ 'id' => k })
                      end
                  InputParameter.load(o, dir, frags, nss)
                }
              end

    @outputs = if obj['outputs'].instance_of? Array
                 obj['outputs'].map{ |o|
                   WorkflowOutputParameter.load(o, dir, frags, nss)
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
                         v.merge({ 'id' => k })
                       end
                   WorkflowOutputParameter.load(o, dir, frags, nss)
                 }
               end
    @class_ = obj['class']
    @steps = if obj['steps'].instance_of? Array
               obj['steps'].map{ |s|
                 WorkflowStep.load(s, dir, frags, nss)
               }
             else
               obj['steps'].map{ |k, v|
                 WorkflowStep.load(v.merge({ 'id' => k }),
                                   dir, frags, nss)
               }
             end
    @id = obj.fetch('id', nil)
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               v.merge({ 'class' => k })
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r, dir, frags, nss)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                v.merge({ 'class' => k })
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h, dir, frags, nss, true)
    }

    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @cwlVersion = obj.fetch('cwlVersion', nil)
    @namespaces = obj.fetch('$namespaces', nil)
    @schemas = obj.fetch('$schemas', nil)
  end

  def self.load_requirement(req, dir, frags, nss, hints = false)
    unless req.include? 'class'
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, 'Invalid requriment object'
      end
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req, dir, frags, nss)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req, dir, frags, nss)
    when 'DockerRequirement'
      DockerRequirement.load(req, dir, frags, nss)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req, dir, frags, nss)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req, dir, frags, nss)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req, dir, frags, nss)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req, dir, frags, nss)
    when 'ResourceRequirement'
      ResourceRequirement.load(req, dir, frags, nss)
    when 'SubworkflowFeatureRequirement'
      SubworkflowFeatureRequirement.load(req, dir, frags, nss)
    when 'ScatterFeatureRequirement'
      ScatterFeatureRequirement.load(req, dir, frags, nss)
    when 'MultipleInputFeatureRequirement'
      MultipleInputFeatureRequirement.load(req, dir, frags, nss)
    when 'StepInputExpressionRequirement'
      StepInputExpressionRequirement.load(req, dir, frags, nss)
    else
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, "Invalid requirement: #{req['class']}"
      end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.inputs = @inputs.map{ |inp|
      inp.evaluate(js_req, inputs, runtime, inputs[inp.id])
    }
    ret.outputs = @outputs.map{ |out|
      out.evaluate(js_req, inputs, runtime, self_)
    }
    ret.steps = @steps.map{ |s|
      s.evaluate(js_req, inputs, runtime, self_)
    }
    ret.requirements = @requirements.map{ |req|
      req.evaluate(js_req, inputs, runtime, self_)
    }
    ret.hints = @hints.map{ |h|
      h.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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
    ret['id'] = @id unless @id.nil?

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

    ret['label'] = @label unless @label.nil?
    ret['doc'] = @doc unless @doc.nil?
    ret['cwlVersion'] = @cwlVersion unless @cwlVersion.nil?
    ret['$namespaces'] = @namespaces unless @namespaces.nil?
    ret['$schemas'] = @schemas unless @schemas.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec, dir, frags, nss)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'], dir, frags, nss)]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
    @format = if obj.include? 'format'
                f = obj['format']
                case f
                when %r!^(.+):[^/]!
                  ns = $1
                  unless nss.include? ns
                    raise CWLParseError, "No such namespace: #{ns}"
                  end
                  Expression.load(f.sub(/^#{ns}:/, nss[ns]), dir, frags, nss)
                else
                  Expression.load(f, dir, frags, nss)
                end
              end
    @outputSource = if obj.fetch('outputSource', []).instance_of? Array
                      obj.fetch('outputSource', []).map{ |s| trim_source(s) }
                    else
                      [trim_source(obj['outputSource'])]
                    end
    @linkMerge = if obj.include? 'linkMerge'
                   LinkMergeMethod.load(obj['linkMerge'], dir, frags, nss)
                 else
                   LinkMergeMethod.load('merge_nested', dir, frags, nss)
                 end
    @type = if obj.include? 'type'
              CWLOutputType.load(obj['type'], dir, frags, nss)
            end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.secondaryFiles = @secondaryFiles.map{ |sec|
      sec.evaluate(js_req, inputs, runtime, self_)
    }
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret.format = @format.evaluate(js_req, inputs, runtime, self_) unless @format.nil?
    ret.type = @type.evaluate(js_req, inputs, runtime, self_) unless @type.nil?
    ret
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['label'] = @label unless @label.nil?

    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |s|
        s.to_h
      }
    end

    ret['streamable'] = @streamable if @streamable
    ret['doc'] = @doc unless @doc.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret['format'] = @format.to_h unless @format.nil?
    ret['outputSource'] = @outputSource unless @outputSource.empty?
    ret['linkMerge'] = @linkMerge unless @linkMerge != 'merge_nested'
    ret['type'] = @type.to_h unless @type.nil?
    ret
  end
end

class LinkMergeMethod
  def self.load(obj, dir, frags, nss)
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @type = obj['type']
    @fields = if obj.fetch('fields', []).instance_of? Array
                obj.fetch('fields', []).map{ |f|
                  OutputRecordField.load(f, dir, frags, nss)
                }
              else
                obj.map{ |k, v|
                  o = if v.instance_of? String or
                        v.instance_of? Array or
                        ['record', 'enum', 'array'].include? v.fetch('type', nil)
                        {
                          'name' => k,
                          'type' => v,
                        }
                      else
                        v.merge({ 'name' => k })
                      end
                  OutputRecordField.load(o, dir, frags, nss)
                }
              end
    @label = obj.fetch('label', nil)
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.fields = @fields.map{ |f|
      f.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @name = obj['name']
    @type = CWLOutputType.load(obj['type'], dir, frags, nss)
    @doc = obj.fetch('doc', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.type = @type.evaluate(js_req, inputs, runtime, self_)
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj[ nss])
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @symbols = obj['symbols']
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret
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

class OutputArraySchema < CWLObject
  cwl_object_preamble :items, :type, :label, :outputBinding

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('items') and
      obj.include?('type')
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @items = CWLOutputType.load(obj['items'], dir, frags, nss)
    @type = obj['type']
    @label = obj.fetch('label', nil)
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.items = @items.evaluate(js_req, inputs, runtime, self_)
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret
  end

  def to_h
    ret = {}
    ret['items'] = @items.to_h
    ret['type'] = @type.to_h
    ret['label'] = @label unless @label.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @in = if obj['in'].instance_of? Array
            obj['in'].map{ |o|
              WorkflowStepInput.load(o, dir, frags, nss)
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
                    v.merge({ 'id' => k })
                  end
              WorkflowStepInput.load(o, dir, frags, nss)
            }
          end
    @out = obj['out'].map{ |o|
      if o.instance_of? String
        WorkflowStepOutput.load({ 'id' => o }, dir, frags, nss)
      else
        WorkflowStepOutput.load(o, dir, frags, nss)
      end
    }
    @run = if obj['run'].instance_of? String
             obj['run']
           else
             CommonWorkflowLanguage.load(obj['run'], dir, frags, nss)
           end
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               v.merge({ 'class' => k })
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r, dir, frags, nss)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                v.merge({ 'class' => k })
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h, dir, frags, nss, true)
    }

    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @scatter = if obj.fetch('scatter', []).instance_of? Array
                 obj.fetch('scatter', [])
               else
                 [obj['scatter']]
               end
    @scatterMethod = if obj.include? 'scatterMethod'
                       ScatterMethod.load(obj['scatterMethod'], dir, frags, nss)
                     end
  end

  def self.load_requirement(req, dir, frags, nss, hints = false)
    unless req.include? 'class'
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, 'Invalid requriment object'
      end
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req, dir, frags, nss)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req, dir, frags, nss)
    when 'DockerRequirement'
      DockerRequirement.load(req, dir, frags, nss)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req, dir, frags, nss)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req, dir, frags, nss)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req, dir, frags, nss)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req, dir, frags, nss)
    when 'ResourceRequirement'
      ResourceRequirement.load(req, dir, frags, nss)
    when 'SubworkflowFeatureRequirement'
      SubworkflowFeatureRequirement.load(req, dir, frags, nss)
    when 'ScatterFeatureRequirement'
      ScatterFeatureRequirement.load(req, dir, frags, nss)
    when 'MultipleInputFeatureRequirement'
      MultipleInputFeatureRequirement.load(req, dir, frags, nss)
    when 'StepInputExpressionRequirement'
      StepInputExpressionRequirement.load(req, dir, frags, nss)
    else
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, "Invalid requirement: #{req['class']}"
      end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.in = @in.map{ |i|
      i.evaluate(js_req, inputs, runtime, self_)
    }
    ret.run = @run.evaluate(js_req, inputs, runtime, self_)
    ret.requirement = @requirement.map{ |req|
      req.evaluate(js_req, inputs, runtime, self_)
    }
    ret.hints = @hints.map{ |h|
      h.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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
    ret['label'] = @label unless @label.nil?
    ret['doc'] = @doc unless @doc.nil?
    ret['scatter'] = @scatter unless @scatter.empty?
    ret['scatterMethod'] = @scatterMethod unless @scatterMethod.nil?
    ret
  end
end

class WorkflowStepInput < CWLObject
  cwl_object_preamble :id, :source, :linkMerge, :default, :valueFrom

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id')
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @source = if obj.fetch('source', []).instance_of? Array
                obj.fetch('source', []).map{ |s| trim_source(s) }
              else
                [trim_source(obj['source'])]
              end
    @linkMerge = if obj.include? 'linkMerge'
                   LinkMergeMethod.load(obj['linkMerge'], dir, frags, nss)
                 else
                   LinkMergeMethod.load('merge_nested', dir, frags, nss)
                 end
    @default = if obj.include? 'default'
                 InputParameter.parse_object(nil, obj['default'], dir, frags, nss)
               end
    @valueFrom = if obj.include? 'valueFrom'
                   Expression.load(obj['valueFrom'], dir, frags, nss)
                 end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.valueFrom = @valueFrom.evaluate(js_req, inputs, runtime, self_) unless @valueFrom.nil?
    ret
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['source'] = @source unless @source.empty?
    ret['linkMerge'] = @linkMerge unless @linkMerge == 'merge_nested'
    ret['default'] = @default.to_h unless @default.nil?
    ret['valueFrom'] = @valueFrom.to_h unless @valueFrom.nil?
    ret
  end
end

class WorkflowStepOutput < CWLObject
  cwl_object_preamble :id

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('id')
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @id = trim(obj['id'])
  end

  def to_h
    {
      'id' => @id,
    }
  end
end

class ScatterMethod
  def self.load(obj, dir, frags, nss)
    case obj
    when 'dotproduct', 'nested_crossproduct', 'flat_crossproduct'
      obj
    else
      raise CWLParseError, "Unsupported scatter method: #{obj}"
    end
  end
end

class UnknownRequirement < CWLObject
  attr_reader :params

  def self.load(obj, dir, frags, nss)
    self.new(obj)
  end

  def initialize(obj)
    @params = obj
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
  end

  def to_h
    @params
  end
end

class SubworkflowFeatureRequirement < CWLObject
  cwl_object_preamble :class_

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.fetch('class', '') == 'SubworkflowFeatureRequirement'
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, nss)
  end

  def initialize(obj, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @class_ = obj['class']
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    self
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
                      :doc, :cwlVersion, :namespaces, :schemas

  def self.satisfies_additional_constraints(obj)
    obj.instance_of?(Hash) and
      obj.include?('inputs') and
      obj.include?('outputs') and
      obj.fetch('class', '') == 'ExpressionTool' and
      obj.include?('expression')
  end

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end
    @inputs = if obj['inputs'].instance_of? Array
                obj['inputs'].map{ |o|
                  InputParameter.load(o, dir, frags, nss)
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
                        v.merge({ 'id' => k })
                      end
                  InputParameter.load(o, dir, frags, nss)
                }
              end
    @outputs = if obj['outputs'].instance_of? Array
                obj['outputs'].map{ |o|
                  ExpressionToolOutputParameter.load(o, dir, frags, nss)
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
                        v.merge({ 'id' => k })
                      end
                  ExpressionToolOutputParameter.load(o, dir, frags, nss)
                }
               end
    @class_ = obj['class']
    @expression = Expression.load(obj['expression'], dir, frags, nss)
    @id = obj.fetch('id', nil)
    reqs = if obj.fetch('requirements', []).instance_of? Array
             obj.fetch('requirements', [])
           else
             obj['requirements'].map{ |k, v|
               v.merge({ 'class' => k })
             }
           end
    @requirements = reqs.map{ |r|
      self.class.load_requirement(r, dir, frags, nss)
    }

    hints = if obj.fetch('hints', []).instance_of? Array
              obj.fetch('hints', [])
            else
              obj['hints'].map{ |k, v|
                v.merge({ 'class' => k })
              }
            end
    @hints = hints.map{ |h|
      self.class.load_requirement(h, dir, frags, nss, true)
    }
    @label = obj.fetch('label', nil)
    @doc = obj.fetch('doc', nil)
    @cwlVersion = obj.fetch('cwlVersion', nil)
    @namespaces = obj.fetch('$namespaces', nil)
    @schemas = obj.fetch('$schemas', nil)
  end

  def self.load_requirement(req, dir, frags, nss, hints = false)
    unless req.include? 'class'
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, 'Invalid requriment object'
      end
    end

    case req['class']
    when 'InlineJavascriptRequirement'
      InlineJavascriptRequirement.load(req, dir, frags, nss)
    when 'SchemaDefRequirement'
      SchemaDefRequirement.load(req, dir, frags, nss)
    when 'DockerRequirement'
      DockerRequirement.load(req, dir, frags, nss)
    when 'SoftwareRequirement'
      SoftwareRequirement.load(req, dir, frags, nss)
    when 'InitialWorkDirRequirement'
      InitialWorkDirRequirement.load(req, dir, frags, nss)
    when 'EnvVarRequirement'
      EnvVarRequirement.load(req, dir, frags, nss)
    when 'ShellCommandRequirement'
      ShellCommandRequirement.load(req, dir, frags, nss)
    when 'ResourceRequirement'
      ResourceRequirement.load(req, dir, frags, nss)
    when 'SubworkflowFeatureRequirement'
      SubworkflowFeatureRequirement.load(req, dir, frags, nss)
    when 'ScatterFeatureRequirement'
      ScatterFeatureRequirement.load(req, dir, frags, nss)
    when 'MultipleInputFeatureRequirement'
      MultipleInputFeatureRequirement.load(req, dir, frags, nss)
    when 'StepInputExpressionRequirement'
      StepInputExpressionRequirement.load(req, dir, frags, nss)
    else
      if hints
        return UnknownRequirement.load(req, dir, frags, nss)
      else
        raise CWLParseError, "Invalid requirement: #{req['class']}"
      end
    end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.inputs = @inputs.map{ |inp|
      inp.evaluate(js_req, inputs, runtime, inputs[inp.id])
    }
    ret.outputs = @outputs.map{ |out|
      out.evaluate(js_req, inputs, runtime, self_)
    }
    ret.expression = @expression.evaluate(js_req, inputs, runtime, self_)
    ret.requirements = @requirements.map{ |req|
      req.evaluate(js_req, inputs, runtime, self_)
    }
    ret.hints = @hints.map{ |h|
      h.evaluate(js_req, inputs, runtime, self_)
    }
    ret
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
    ret['id'] = @id unless @id.nil?
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
    ret['label'] = @label unless @label.nil?
    ret['doc'] = @doc unless @doc.nil?
    ret['cwlVersion'] = @cwlVersion unless @cwlVersion.nil?
    ret['$namespaces'] = @namespaces unless @namespaces.nil?
    ret['$schemas'] = @schemas unless @schemas.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec, dir, frags, nss)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'], dir, frags, nss)]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    # TODO
    @format = if obj.fetch('format', []).instance_of? Array
                obj.fetch('format', []).map{ |f|
                  Expression.load(f, dir, frags, nss)
                }
              else
                [Expression.load(obj['format'], dir, frags, nss)]
              end
    @inputBinding = if obj.include? 'inputBinding'
                      CommandLineBinding.load(obj['inputBinding'], dir, frags, nss)
                    end
    @type = if obj.include? 'type'
              CWLInputType.load(obj['type'], dir, frags, nss)
            end
    @default = if obj.include? 'default'
                 if @type.nil?
                   raise CWLParseError, 'Unsupported format: `default` without `type`'
                 end
                 InputParameter.parse_object(@type, obj['default'], dir, frags, nss)
               end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.secondaryFiles = @secondaryFiles.map{ |sec|
      sec.evaluate(js_req, inputs, runtime, self_)
    }
    ret.format = @format.map{ |f|
      f.evaluate(js_req, inputs, runtime, self_)
    }
    ret.inputBinding = @inputBinding.evaluate(js_req, inputs, runtime, self_) unless @inputBinding.nil?
    ret.type = @type.evaluate(js_req, inputs, runtime, self_) unless @type.nil?
    ret
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['label'] = @label unless @label.nil?
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |s|
        s.to_h
      }
    end
    ret['streamable'] = @streamable if @streamable
    ret['doc'] = @doc unless @doc.nil?
    unless @format.empty?
      ret['format'] = @format.map{ |f| f.to_h }
    end
    ret['inputBinding'] = @inputBinding.to_h unless @inputBinding.nil?
    ret['default'] = @default.to_h unless @default.nil?
    ret['type'] = @type.to_h unless @type.nil?
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

  def self.load(obj, dir, frags, nss)
    self.new(obj, dir, frags, nss)
  end

  def initialize(obj, dir, frags, nss)
    unless self.class.valid?(obj, nss)
      raise CWLParseError, "Cannot parse as #{self.class}"
    end

    @id = trim(obj['id'])
    @label = obj.fetch('label', nil)
    @secondaryFiles = if obj.fetch('secondaryFiles', []).instance_of? Array
                        obj.fetch('secondaryFiles', []).map{ |sec|
                          Expression.load(sec, dir, frags, nss)
                        }
                      else
                        [Expression.load(obj['secondaryFiles'], dir, frags, nss)]
                      end
    @streamable = obj.fetch('streamable', false)
    @doc = if obj.include? 'doc'
             obj['doc'].instance_of?(Array) ? obj['doc'].join : obj['doc']
           end
    @outputBinding = if obj.include? 'outputBinding'
                       CommandOutputBinding.load(obj['outputBinding'], dir, frags, nss)
                     end
    @format = if obj.include? 'format'
                Expression.load(obj['format'], dir, frags, nss)
              end
    @type = if obj.include? 'type'
              CWLOutputType.load(obj['type'], dir, frags, nss)
            end
  end

  def evaluate(js_req, inputs, runtime, self_ = nil)
    ret = self.dup
    ret.secondaryFiles = @secondaryFiles.map{ |sec|
      sec.evaluate(js_req, inputs, runtime, self_)
    }
    ret.outputBinding = @outputBinding.evaluate(js_req, inputs, runtime, self_) unless @outputBinding.nil?
    ret.format = @format.evaluate(js_req, inputs, runtime, self_) unless @format.nil?
    ret.type = @type.evaluate(js_req, inputs, runtime, self_) unless @type.nil?
    ret
  end

  def to_h
    ret = {}
    ret['id'] = @id
    ret['label'] = @label unless @label.nil?
    unless @secondaryFiles.empty?
      ret['secondaryFiles'] = @secondaryFiles.map{ |s|
        s.to_h
      }
    end
    ret['streamable'] = @streamable if @streamable
    ret['doc'] = @doc unless @doc.nil?
    ret['outputBinding'] = @outputBinding.to_h unless @outputBinding.nil?
    ret['format'] = @format.to_h unless @format.nil?
    ret['type'] = @type.to_h unless @type.nil?
    ret
  end
end

class InputParameter
  def self.parse_object(type, obj, dir, frags, nss)
    if type.nil? or (type.instance_of?(CWLType) and type.type == 'Any')
      type = guess_type(obj)
    end

    case obj
    when CWLFile, Directory
      return obj
    end

    case type
    when CWLType
      case type.type
      when 'null'
        unless obj.nil?
          raise CWLInspectionError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'boolean'
        unless obj == true or obj == false
          raise CWLInspectionError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'int', 'long'
        unless obj.instance_of? Integer
          raise CWLInspectionError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'float', 'double'
        unless obj.instance_of? Float
          raise CWLInspectionError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'string'
        unless obj.instance_of? String
          raise CWLInspectionError, "Invalid value: #{obj} but #{type.type} is expected"
        end
        obj
      when 'File'
        CWLFile.load(obj, dir, frags, nss)
      when 'Directory'
        Directory.load(obj, dir, frags, nss)
      end
    when CommandInputRecordSchema, InputRecordSchema
      CWLRecordValue.new(
        Hash[type.fields.map{ |f|
               [f.name, self.parse_object(f.type, obj[f.name], dir, frags, nss)]
             }])
    when CommandInputEnumSchema, InputEnumSchema
      unless obj.instance_of?(String) and type.symbols.include? obj
        raise CWLInspectionError, 'CommandInputEnumSchema is not suppported'
      end
      obj.to_sym
    when CommandInputArraySchema, InputArraySchema
      t = type.items
      unless obj.instance_of? Array
        raise CWLInspectionError, "Invalid value: array of #{t} is expected"
      end
      obj.map{ |o|
        self.parse_object(t, o, dir, frags, nss)
      }
    when CommandInputUnionSchema, InputUnionSchema
      idx = type.types.find_index{ |ty|
        begin
          self.parse_object(ty, obj, dir, frags, nss)
          true
        rescue CWLInspectionError
          false
        end
      }
      if idx.nil?
        raise CWLParseError, "Invalid object: #{obj}"
      end
      CWLUnionValue.new(type.types[idx],
                        self.parse_object(type.types[idx], obj, dir, frags, nss))
    else
      raise CWLInspectionError, "Unknown type: #{type.class}"
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

class CWLRecordValue
  attr_accessor :fields

  def initialize(fields)
    @fields = fields
  end

  def walk(path)
    if path.empty?
      @fields
    else
      f = path.first
      unless @fields.include? f
        raise CWLInspectionError, "No such field: #{f}"
      end
      @fields[f].walk(path[1..-1])
    end
  end

  def to_h
    @fields.transform_values{ |v|
      v.to_h
    }
  end
end

def guess_type(value)
  case value
  when nil
    CWLType.load('null', nil, {}, {})
  when TrueClass, FalseClass
    CWLType.load('boolean', nil, {}, {})
  when Integer
    CWLType.load('int', nil, {}, {})
  when Float
    CWLType.load('float', nil, {}, {})
  when String
    CWLType.load('string', nil, {}, {})
  when Hash
    case value.fetch('class', nil)
    when 'File'
      CWLType.load('File', nil, {}, {})
    when 'Directory'
      CWLType.load('Directory', nil, {}, {})
    else
      CommandInputRecordSchema.load({
                                      'type' => 'record',
                                      'fields' => value.each.map{ |k, v|
                                        {
                                          'name' => k,
                                          'type' => guess_type(v).to_h,
                                        }
                                      }
                                    }, nil, {}, {})
    end
  when Array
    CommandInputArraySchema.load({
                                   'type' => 'array',
                                   'items' => guess_type(value.first).to_h,
                                 }, nil, {}, {})
  when CWLFile
    CWLType.load('File', nil, {}, {})
  when Directory
    CWLType.load('Directory', nil, {}, {})
  else
    raise CWLInspectionError, "Unsupported value: #{value}"
  end
end

class UninstantiatedVariable
  attr_reader :name

  def initialize(var)
    @name = var
  end
end

class InvalidVariable
  attr_reader :name

  def initialize(var)
    @name = var
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
