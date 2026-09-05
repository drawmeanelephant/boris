### Fixed

- `boris-job-runner` accepts standard ustar archives containing directory members: trailing-slash names (`content/`) are validated as the directory path instead of rejected as `archive` ([container-runner contract](/docs/contracts/cloudflare-container-runner.md), #908).
