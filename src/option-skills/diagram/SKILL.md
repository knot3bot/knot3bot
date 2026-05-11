---
name: diagram
description: Generate diagrams and visual representations of architecture, flows, data models, and system designs.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Diagram, Visualization, Architecture, Mermaid, Flowchart]
    category: design
---

# Diagram

Create clear visual representations of technical concepts.

## When to Use
- User asks for a diagram, flowchart, architecture diagram, or visual
- Explaining system architecture or data flow
- Documenting API or database schema
- Planning features or refactors

## Supported Formats
- Mermaid (flowchart, sequence, class, ER, state, gantt)
- ASCII art diagrams for terminal output
- PlantUML when available

## Process
1. Understand the system or concept to visualize
2. Choose the appropriate diagram type
3. Generate using Mermaid syntax (most portable)
4. Explain the diagram in text alongside the visual
5. Offer to iterate on layout or add detail
