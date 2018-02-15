#!/usr/bin/env python
import unittest
from os.path import basename
from cwl_parser import load_document
from cwl_inspector import inspect

CWL = 'examples/echo/echo.cwl'


class TestEcho(unittest.TestCase):

    def setUp(self):
        self.cwl = load_document(CWL)

    def test_version(self):
        self.assertEqual('v1.0', inspect(self.cwl, '.cwlVersion'))

    def test_ID_based_access(self):
        self.assertEqual('Input string',
                         inspect(self.cwl, '.inputs.input.label'))

    def test_index_based_access(self):
        self.assertEqual('Input string',
                         inspect(self.cwl, '.inputs.0.label'))

    def test_commandline(self):
        pass

    def test_instantiated_commandline(self):
        pass

    def test_root_keys(self):
        self.assertEqual(['arguments', 'baseCommand', 'class_', 'cwlVersion',
                          'doc', 'hints', 'id', 'inputs', 'label', 'outputs',
                          'permanentFailCodes', 'requirements', 'stderr',
                          'stdin', 'stdout', 'successCodes',
                          'temporaryFailCodes'],
                         inspect(self.cwl, 'keys(.)'))

    def test_keys(self):
        self.assertEqual(['input'],
                         [basename(f) for f in inspect(self.cwl,
                                                       'keys(.inputs)')])
