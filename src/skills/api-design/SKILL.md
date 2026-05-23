---
name: api-design
description: Design RESTful APIs with proper status codes, error handling, versioning, and documentation
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [API, REST, Design, HTTP, Documentation]
    category: development
---

# API Design

Design clean, consistent, production-ready APIs.

## When to Use
- Designing new API endpoints or microservices
- Reviewing API design for consistency
- Planning API versioning strategy

## Guidelines
- Use proper HTTP methods (GET, POST, PUT, DELETE, PATCH)
- Return appropriate status codes (2xx, 4xx, 5xx)
- Include pagination for list endpoints
- Version APIs via URL path or header
- Document with OpenAPI/Swagger
- Use consistent error response format
- Rate limit sensitive endpoints
- Validate all inputs at the boundary
