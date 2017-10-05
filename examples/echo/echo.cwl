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
  - id: output
    type: string?
    outputBinding: {}
requirements:
  - class: DockerRequirement
    dockerPull: docker/whalesay
