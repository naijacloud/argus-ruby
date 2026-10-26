## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- The decision, or the failure it prevents. The diff already shows what. -->

## Checklist

- [ ] Tests cover the change, and `rake test` passes offline (no network)
- [ ] No real DSN or key is committed (test keys are a run of zeros)
- [ ] The change still follows the Argus SDK contract (`argus.sdk/1`), or the contract is updated with it
- [ ] CHANGELOG.md has an entry under Unreleased

<!--
Every Argus SDK implements one shared wire contract (nc-argus spec/README.md).
If this changes behaviour rather than just this language's spelling of it, the
same change is owed to argus-js and the other SDKs. Say so here.
-->
