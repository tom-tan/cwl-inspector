# cwl-inspector
[![Actions Status](https://github.com/tom-tan/cwl-inspector/workflows/ci/badge.svg)](https://github.com/tom-tan/cwl-inspector/actions)
[![license](https://badgen.net/github/license/tom-tan/cwl-inspector)](https://github.com/tom-tan/cwl-inspector/blob/master/LICENSE)

cwl-inspector provides a handy way to inspect properties of tools or workflows written in Common Workflow Language

# Requirements
- Ruby 2.7 or later

# Running examples

Input: echo.cwl
```yaml
class: CommandLineTool
cwlVersion: v1.0
id: echo_cwl
baseCommand:
  - cowsay
inputs:
  - id: input
    type: string?
    inputBinding:
      position: 0
    label: Input string
    doc: This is an input string
outputs:
  output:
    type: stdout
stdout: output
requirements:
  - class: DockerRequirement
    dockerPull: docker/whalesay
```

## show a property named 'cwlVersion'
```console
$ ./inspector.rb echo.cwl .cwlVersion
--- v1.0
```

## show a nested property
```console
$ ./inspector.rb echo.cwl .requirements.0.class
--- DockerRequirement
```

You can access an input parameter by using its index (specified by `position` field) or its id.

```console
$ ./inspector.rb echo.cwl .inputs.0.label
--- Input string
```

or

```console
$ ./cwl-inspector.rb echo.cwl .inputs.input.label
--- Input string
```

## show keys in the specified property
```console
$ ./inspector.rb echo.cwl 'keys(.)'
---
- inputs
- outputs
- class
- id
- requirements
- cwlVersion
- baseCommand
- stdout
```

## show the command to run a given cwl file
```console
$ ./inspector.rb echo.cwl commandline
docker run -i --read-only --rm --workdir=/private/var/spool/cwl --env=HOME=/private/var/spool/cwl --env=TMPDIR=/tmp --user=501:20 -v /Users/tom-tan/cwl-inspector/examples/echo:/private/var/spool/cwl -v /tmp:/tmp docker/whalesay cowsay > /Users/tom-tan/cwl-inspector/examples/echo/output
```

You can also specify the parameter to show the command with instantiated parameters.
```console
$ cat inputs.yml
input: Hello!
$ ./inspector.rb echo.cwl commandline -i inputs.yml
docker run -i --read-only --rm --workdir=/private/var/spool/cwl --env=HOME=/private/var/spool/cwl --env=TMPDIR=/tmp --user=501:20 -v /Users/tom-tan/cwl-inspector/examples/echo:/private/var/spool/cwl -v /tmp:/tmp docker/whalesay cowsay 'Hello!' > /Users/tom-tan/cwl-inspector/examples/echo/output
```

# Dockerized cwl-inspector
You can use [`ghcr.io/tom-tan/cwl-inspector`](https://github.com/users/tom-tan/packages/container/package/cwl-inspector) image.
This image is built by [Github Actions](https://github.com/tom-tan/cwl-inspector/actions).

```console
$ cat echo.cwl | docker run --rm -i ghcr.io/tom-tan/cwl-inspector:v0.1.1 - .cwlVersion
--- v1.0
```

## using job parameter file

```console
$ cwltool --make-template echo.cwl > echo.yml
$ cat echo.yml
input: a_string  # type "string" (optional)
$ cat echo.cwl | docker run --rm -i -v $PWD/echo.yml:/workdir/echo.yml --workdir=/workdir ghcr.io/tom-tan/cwl-inspector:v0.1.1 -i echo.yml - commandline
env HOME='/workdir' TMPDIR='/tmp' /bin/sh -c 'cd ~ && "cowsay" "a_string"' > /workdir/output
```



# License
This software is released under the [MIT License](https://github.com/tom-tan/cwl-inspector/blob/master/LICENSE).

The following file in `examples` is copied from [common-workflow-language/common-workflow-language](https://github.com/common-workflow-language/common-workflow-language) and is released under [Apache 2.0 License](https://github.com/common-workflow-language/common-workflow-language/blob/master/LICENSE.txt).
- `examples/expression.cwl` ([Source in common-workflow-language/common-workflow-language](https://github.com/common-workflow-language/common-workflow-language/blob/master/v1.0/examples/expression.cwl))
