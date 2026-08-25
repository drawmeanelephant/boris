### Security

- Harden migration-lab conversion: sanitize untrusted JSX attribute values before replay, require path-segment boundaries for WordPress slug link resolution, stop silent asset overwrites when collision disambiguation is exhausted, and keep scanning after an unterminated attribute value. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#717](https://github.com/drawmeanelephant/boris/issues/717).
