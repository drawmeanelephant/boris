### Changed

- Stream [RSS](/docs/contracts/rss-2.0.md), [sitemap](/docs/contracts/xml-sitemap.md), and [rendered-search](/docs/contracts/rendered-search.md) file output through buffered atomic writers without retaining a complete serialized artifact; preserve emitted bytes and the existing in-memory rendering APIs.
