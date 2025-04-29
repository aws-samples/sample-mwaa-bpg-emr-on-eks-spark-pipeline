# UML Diagrams

This directory contains PlantUML diagrams for the BPG Operator architecture.

## Prerequisites

1. Java Runtime Environment (JRE) 8 or newer
2. PlantUML JAR file

## Getting PlantUML

1. Download the PlantUML JAR file:
   - Visit [PlantUML Official Downloads](https://plantuml.com/download)
   - Click on "PlantUML compiled Jar"
   - Or use this direct link: [plantuml.jar](https://github.com/plantuml/plantuml/releases/latest/download/plantuml.jar)

2. Save the JAR file in a known location (e.g., `~/Downloads/` or a project-specific tools directory)

## Available Diagrams

- `bpg_operator.puml` - Class diagram showing BPG Operator structure and dependencies
- `bpg_operator_sequence.puml` - Sequence diagram showing BPG Operator execution flow

## Generating Diagrams

Generate SVG and PNG iles from the PlantUML source:

```bash
# Class Diagram
java -jar /path/to/plantuml.jar -tsvg bpg_operator.puml

# Sequence Diagram
java -jar /path/to/plantuml.jar -tsvg bpg_operator_sequence.puml

# Class Diagram
java -jar /path/to/plantuml.jar -tpng bpg_operator.puml

# Sequence Diagram
java -jar /path/to/plantuml.jar -tpng bpg_operator_sequence.puml


