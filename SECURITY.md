# Security

Found a way these scripts leave a server, a token, or a site more exposed than they
claim? Please open a [private security advisory](../../security/advisories/new) rather
than a public issue.

What this repo promises, and tests in CI:
- no inbound port is opened for the website; the tunnel dials out
- SSH is key-only with root login off, verified against the effective config (`sshd -T`)
- no container is published beyond 127.0.0.1
- API and tunnel tokens are never printed; they live in mode-600 files
- a domain is never bought without typing its exact name
