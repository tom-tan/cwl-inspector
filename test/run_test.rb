#!/usr/bin/env ruby

CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')

if $0 == __FILE__
  base_dir = File.expand_path(File.join(File.dirname(__FILE__), ".."))
  lib_dir  = File.join(base_dir, "lib")
  test_dir = File.join(base_dir, "test")

  $LOAD_PATH.unshift(lib_dir)

  require 'test/unit'

  exit Test::Unit::AutoRunner.run(true, test_dir)
end
