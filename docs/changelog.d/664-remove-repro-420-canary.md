### Changed

- Removed the retired `repro/420` regression canary ([#420](https://github.com/drawmeanelephant/boris/issues/420)); the Touch Atlas streaming-checks parse bug it guarded is fixed on `afterparty` (the harness now exits with the expected *"did NOT reproduce"* result), and it was unwired from CI, so the dead canary no longer ships in the repository.
