# Security policy

## Supported code

Security fixes are applied to the current Windows branch. This project does not
currently maintain older release branches.

## Reporting a vulnerability

Please use this repository's **Private vulnerability reporting** feature under
the Security tab. Include:

- the affected commit or version;
- the Windows version and reproduction steps;
- the expected and observed security boundary;
- a minimal proof of concept, with secrets and personal documents removed.

Do not open a public issue for a vulnerability that has not yet been remediated.
Ordinary bugs without security impact can use the public issue tracker.

## Bridge security model

The native bridge:

- is disabled until started explicitly from Ipe's Ipelets menu;
- binds exclusively to `127.0.0.1`;
- accepts one request at a time;
- closes when stopped or when Ipe exits;
- has frame-size limits for requests and responses.

The bridge does not authenticate local clients. While it is active, any local
process able to connect to its port may request diagram reads, edits, renders,
or saves. Use it only during an intentional collaboration session, stop it when
finished, and never expose the port through a proxy, port forward, container
mapping, or firewall rule.

This repository does not upload document data. The MCP client and model provider
you choose may process tool inputs and results elsewhere; consult their privacy
and retention policies before using sensitive diagrams.
