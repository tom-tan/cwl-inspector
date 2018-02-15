#!/usr/bin/env python
"""This module is an entrypoint for cwl_inspector."""
from cwl_parser import load_document, save
import sys
import argparse
import os
import os.path
import re
import yaml
import json


def argparser():
    """Return a basic argparser for cwl_inspector."""
    parser = argparse.ArgumentParser(
        description='Inspector for Common Workflow Language')
    parser.add_argument('--outdir', type=str, default=os.path.abspath('.'),
                        help='Output directory (default: current directory)')
    parser.add_argument('--tmpdir', type=str, help='Temporary directory')
    parser.add_argument('--yaml', help='Print in YAML format',
                        action='store_true')
    parser.add_argument('--json', help='Print in JSON format',
                        action='store_true')
    parser.add_argument('doc', type=str, help='CWL document for inspction')
    parser.add_argument('pos', type=str, help='Position to be inspection')
    return parser


def inspect_position(cwl, pos):
    """Return an object in a given position."""
    if pos == '.':
        return cwl

    cur_obj = cwl
    for po in pos[1:].split('.'):
        if re.match('^\d+$', po):
            po = int(po)
            if not isinstance(cur_obj, list) or po >= len(cur_obj):
                raise Exception(f'No such field {pos}')
            cur_obj = cur_obj[po]
        elif isinstance(cur_obj, list):
            field = next((f for f in cur_obj if os.path.basename(f.id) == po),
                         None)
            if field is None:
                raise Exception(f'No such field {pos}')
            cur_obj = field
        else:
            if po not in cur_obj.__dict__:
                raise Exception(f'No such field {pos}')

            val = cur_obj.__dict__[po]
            if po == 'basecommand' and isinstance(val, str):
                cur_obj = [val]
            else:
                if po == 'inputBinding' and \
                   'position' not in cur_obj.inputBinding.__dict__:
                    setattr(cur_obj.inputBinding, 'position', 0)
                cur_obj = val
    return cur_obj


def to_command(cwl, env):
    pass


def to_step_command(cwl, obj, env):
    pass


def ls_outputs_for_command(cwl, obj, env):
    pass


def inspect(cwl, pos, env):
    """Return an object as a result of inspection."""
    if pos.startswith('.'):
        return inspect_position(cwl, pos)
    elif pos.startswith('keys('):
        obj = re.match('^keys\((.+)\)$', pos).group(1)
        return list(inspect_position(cwl, obj).__dict__.keys())
    elif pos == 'commandline':
        if cwl.class_ != 'CommandLineTool':
            raise Exception('commandline for Workflow needs an argument')
        return to_command(cwl, env)
    elif pos.startswith('commandline('):
        if cwl.class_ != 'Workflow':
            raise Exception(
                'commandline for CommandLineTool does not need an argument')
        obj = re.match('^commandline\((.+)\)$', pos).group(1)
        return to_step_command(cwl, obj, env)
    elif pos.startswith('ls(.outputs.'):
        if cwl.class_ == 'Workflow':
            raise Exception('Not yet implemented it for Workflow')
        elif cwl.class_ == 'CommandLineTool':
            obj = re.match('^ls\((.+)\)$', pos).group(1)
            return ls_outputs_for_command(cwl, obj, env)
        else:
            raise Exception(f'Unsupported class {cwl.class_}')
    elif pos.startswith('ls(.steps.)'):
        if cwl.class_ != 'Workflow':
            raise Exception(
                'ls outputs for steps does not work for CommandLineTool')
        raise Exception('Not yet implemented')
    else:
        raise Exception(f'Unknown pos: {pos}')


def cwl_inspector(args):
    """
    Run the entrypoint for cwl_inspector.

    It also parses the commandline arguments.
    """
    ap = argparser()
    args = ap.parse_args(sys.argv[1:])

    if not args.doc:
        ap.print_help()
        return 0

    fname = args.doc
    if not os.path.exists(fname):
        raise Exception("File not found: "+args.doc)
    cwl = load_document(fname)

    outdir = args.outdir if args.outdir else os.getcwd()
    outdir = os.path.abspath(outdir)

    tmpdir = args.tmpdir if args.tmpdir else None

    env = {
        'runtime': {
            'outdir': outdir,
            'tmpdir': tmpdir,
        },
        'args': {},
    }
    ret = inspect(cwl, args.pos, env)

    if args.yaml:
        print(yaml.dump(save(ret)))
    elif args.json:
        print(json.dumps(save(ret), indent=4))
    else:
        print(save(ret))


if __name__ == '__main__':
    sys.exit(cwl_inspector(sys.argv[1:]))
