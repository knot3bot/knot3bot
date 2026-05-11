---
name: security-audit
description: Comprehensive security audit covering OWASP Top 10, injection, auth, cryptography, and supply chain risks.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Security, Audit, OWASP, Vulnerability, Penetration Testing]
    category: security
---

# Security Audit

Thorough security review of code, configuration, and infrastructure.

## When to Use
- Security audit or penetration test requested
- Before deploying to production
- Evaluating third-party dependencies
- Compliance review

## Audit Checklist

### Injection
- SQL, NoSQL, OS command, LDAP, XPath injection vectors
- Input validation and sanitization
- Parameterized queries vs string concatenation

### Authentication & Authorization
- Password policies, MFA, session management
- JWT validation, token storage, refresh token rotation
- Role-based access control enforcement
- API key handling and rotation

### Data Protection
- Encryption at rest and in transit
- Sensitive data exposure in logs, errors, or responses
- PII handling and data retention policies
- Secure credential storage (no hardcoded secrets)

### Supply Chain
- Dependency vulnerabilities (known CVEs)
- Build pipeline security
- Code signing and integrity verification
- Third-party service risk assessment

### Configuration
- Secure defaults, principle of least privilege
- CORS, CSP, HSTS, and other security headers
- TLS configuration and certificate management
- Environment isolation (dev/staging/prod)
