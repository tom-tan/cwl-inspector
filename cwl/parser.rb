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

class CWLParseError < Exception
end

class CommonWorkflowLanguage
  def self.load_file(file)
    obj = YAML.load_file(file)
    self.load(obj)
  end

  def self.load(obj)
    case obj.fetch('class', '')
    when 'CommandLineTool'
      CommandLineTool.new(obj)
    when 'Workflow'
      Workflow.new(obj)
    when 'ExpressionTool'
      raise 'ExpressionTool is not supported'
    else
      raise CWLParseError, 'Cannot parse as #{self}'
    end
  end
end

def test
  CommonWorkflowLanguage.load_file('examples/echo/echo.cwl')
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
          class_variable_get(:@@fields).map{ |m| m == :class_ ? :class : m }.any?{ |f| f.to_s == k }
        } and satisfies_additional_constraints(obj)
      end
    }
  end

  def self.satisfies_additional_constraints(obj)
    true
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
        Expression.load(arg)
      end
    }
    @stdin = obj.include?('stdin') ? Expression.load(obj['stdin']) : nil
    @stderr = obj.include?('stderr') ? Expression.load(obj['stderr']) : nil
    @stdout = obj.include?('stdout') ? Expression.load(obj['stdout']) : nil
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
      raise CWLParseError, "Invalid reqirement: #{req['class']}"
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
    @default = if obj.include? 'default'
                 # type?
                 raise CWLParseError, "Unsupported `default` in #{self.class}"
               end
    @type = if obj.include? 'type'
              CWLInputType.load(obj['type'])
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

class CWLInputType
  attr_reader :type

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    case obj
    when Array
      unless obj.length == 2 and obj[1] == 'null'
        raise CWLParseError, "Cannot parse as #{self.class}"
      end
      @optional = true
      @type = self.class.load(obj[0])
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        @type = CommandInputRecordSchema.load(obj)
      when 'enum'
        @type = CommandInputEnumSchema.load(obj)
      when 'array'
        @type = CommandInputArraySchema.load(obj)
      end
    when /^(.+)\?$/
      @type = self.class.load([$1, 'null'])
    when /^(.+)\[\]$/
      @type = self.class.load({
                                'type' => array,
                                'items' => $1,
                              })
    when 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory' # CWLType
      @type = obj
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end

  def optional?
    @optional
  end

  def to_h
    t = if @type.instance_of? String
          @type
        else
          @type.to_h
        end
    @optional ? [t, 'null'] :  t
  end
end

class CWLOutputType
  attr_reader :type

  def self.load(obj)
    self.new(obj)
  end

  def initialize(obj)
    case obj
    when Array
      unless obj.length == 2 and obj[1] == 'null'
        raise CWLParseError, "Cannot parse as #{self.class}"
      end
      @optional = true
      @type = self.class.load(obj[0])
    when Hash
      unless obj.include? 'type'
        raise CWLParseError, 'Invalid type object: #{obj}'
      end
      case obj['type']
      when 'record'
        @type = CommandOutputRecordSchema.load(obj)
      when 'enum'
        @type = CommandOutputEnumSchema.load(obj)
      when 'array'
        @type = CommandOutputArraySchema.load(obj)
      end
    when /^(.+)\?$/
      @type = self.class.load([$1, 'null'])
    when /^(.+)\[\]$/
      @type = self.class.load({
                                'type' => array,
                                'items' => $1,
                              })
    when 'stdout', 'stderr'
      @type = obj
    when 'boolean', 'int', 'long', 'float', 'double',
         'string', 'File', 'Directory' # CWLType
      @type = obj
    else
      raise CWLParseError, "Unimplemented type: #{obj}"
    end
  end

  def optional?
    @optional
  end

  def to_h
    t = if @type.instance_of? String
          @type
        else
          @type.to_h
        end
    @optional ? [t, 'null'] :  t
  end
end

class CWLFile < CWLObject
  cwl_object_preamble :class_, :location, :path, :basename, :dirname,
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

  def to_h
    ret = {}
    ret['class'] = @class_
    ret['location'] = @location unless @location.nil?
    ret['path'] = @path unless @path.nil?
    ret['basename'] = @basename unless @basename.nil?
    ret['dirname'] = @dirname unless @dirname.nil?
    ret['nameroot'] = @nameroot unless @nameroot.nil?
    ret['nameext'] = @nameext unless @nameext.nil?
    ret['cehcksum'] = @checksum unless @checksum.nil?
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
    unless valid?(obj)
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
              CWLOutputType.load(obj['type'])
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
    @fields = obj.fetch('fields').map{ |f|
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
    @type = CWLOutputType.load(obj['type'])
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

class Expression
  def self.load(obj)
    Expression.new(obj)
  end

  def initialize(exp)
    @expression = exp
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


if $0 == __FILE__
  format = :yaml
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} cwl"
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
