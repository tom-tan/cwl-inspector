#!/usr/bin/env ruby
# coding: utf-8
require 'test/unit'
require_relative '../cwl-inspector'

CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')

class TestEcho < Test::Unit::TestCase
  def test_version
    assert_equal(cwl_inspect("#{CWL_PATH}/echo.cwl", 'cwlVersion'),
                 'v1.0')
  end

  def test_commandline
    assert_equal(cwl_inspect("#{CWL_PATH}/echo.cwl", 'commandline'),
                 'docker run --rm docker/whalesay cowsay [ $input ]')
  end
end
