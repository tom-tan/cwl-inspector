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
