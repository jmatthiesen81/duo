# duo

Publishes a built `dist` package into a version-branched distribution
repository as part of a GitLab release.

Given a release tag and an already-built `dist` directory, the tool commits
and pushes that directory's content into another git repository, on the
branch that corresponds to the release's `major.minor` version.

## Why

Some projects keep their built distributable output in a separate
repository, organized as one branch per `major.minor` release line (e.g.
`6.4`, `6.5`, ...), with each release as a commit + tag on that branch. This
script automates publishing a release into that repository from a GitLab CI
pipeline (or manually), including the branching/versioning rules described
below.

## Usage

```
scripts/publish-dist-release.sh --tag <version> --dist <path> --target-repo <url> [--commit-message <msg>]
```

| Argument            | Required | Description                                                                          |
|---------------------|----------|----------------------------------------------------------------------------------------|
| `--tag`             | yes      | Full release tag, e.g. `6.4.6-p2607131241`                                            |
| `--dist`            | yes      | Path to the already-built dist directory                                              |
| `--target-repo`     | yes      | Git URL of the target repository, with auth already embedded (HTTPS token or SSH)     |
| `--commit-message`  | no       | Overrides the default commit message (`Release <published-version>`)                  |
| `-h`, `--help`      | no       | Show usage                                                                             |

The script only needs `bash` and `git` on `PATH`. It does not handle
authentication itself — pass a `--target-repo` URL that is already
authenticated (e.g. `https://oauth2:<token>@gitlab.example.com/group/dist-repo.git`
or an SSH URL with a key already configured).

## Version and branch rules

- **Target branch**: the tag's `major.minor` (e.g. `6.4.6-p2607131241` ->
  branch `6.4`).
- **Branch doesn't exist yet**: it is created from the tip of the closest
  existing branch with a *lower* `major.minor` version (e.g. creating `6.5`
  when only `6.3` and `6.4` exist branches it off `6.4`). If no lower
  version branch exists, a fresh, empty branch is created.
- **Branch already exists**: the release is committed directly onto it.
- **Published version**: the `-p<digits>` build-timestamp suffix is
  stripped from the tag before it's used as the target repo's tag/commit
  message (e.g. `6.4.6-p2607131241` -> `6.4.6`). `-rc...` release-candidate
  suffixes are kept as-is (e.g. `6.5.0-rc1` stays `6.5.0-rc1`).
- **Duplicate versions**: if the published version's tag already exists in
  the target repo, the script aborts with an error and pushes nothing.
- **Content**: the dist directory's content replaces the entire content of
  the target branch (everything except `.git`).

## Example

```sh
scripts/publish-dist-release.sh \
  --tag 6.4.6-p2607131241 \
  --dist ./dist \
  --target-repo https://oauth2:$DIST_REPO_TOKEN@gitlab.example.com/group/dist-repo.git
```

This publishes to branch `6.4` of the target repo, tagged `6.4.6`.

## GitLab CI

See [`.gitlab-ci.yml`](.gitlab-ci.yml) for a demo pipeline: it builds the
project, then on tag pipelines runs `publish-dist-release.sh` to push the
build output to a separate distribution repository configured via the
`DIST_REPO_URL` CI/CD variable.

## Docker image

A [`Dockerfile`](Dockerfile) packages the script with `bash` and `git` so it
can be run without any local setup:

```sh
docker run --rm \
  -v "$(pwd)/dist:/dist" \
  ghcr.io/jmatthiesen81/duo:latest \
  --tag 6.4.6-p2607131241 \
  --dist /dist \
  --target-repo https://oauth2:$DIST_REPO_TOKEN@gitlab.example.com/group/dist-repo.git
```

## GitHub Actions

- [`.github/workflows/release.yml`](.github/workflows/release.yml) creates a
  GitHub Release (with auto-generated notes) whenever a version tag is
  pushed; tags containing `-rc` are marked as a pre-release.
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml)
  builds the `Dockerfile` and pushes it to the GitHub Container Registry
  (`ghcr.io/<owner>/<repo>`) tagged with the pushed tag and `latest`.
