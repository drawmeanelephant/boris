### Security

- Fix a use-after-free in `boris-content-audit`: policy and previous-report JSON parsing now uses a leaky parse so retained keys/values/delta strings live for the run instead of pointing into a freed parse tree. See [`tools/content-audit/src/policy.zig`](/tools/content-audit/src/policy.zig) and [#710](https://github.com/drawmeanelephant/boris/issues/710).
