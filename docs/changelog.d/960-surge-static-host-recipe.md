### Docs

- Added a [Surge.sh static-host recipe](/docs/surge.md): the shell path from `dist/` to a Surge domain, with the declared-versus-deployment-owned `CNAME` distinction (a Surge-written `dist/CNAME` survives a rebuild untouched; `--static-dir static` makes it an inventoried artifact), the `_boris/proof/` upload boundary a bare `surge ./dist` does not enforce, preview/revision/rollback commands, and a scoped-token CI example. Surge stays a commodity host with no `publication.target` name; [the platform model](/docs/contracts/publication-platforms.md) is unchanged (#848).
