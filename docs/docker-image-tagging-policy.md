# Docker Image Tagging Policy

## Overview

This repository builds and publishes Docker images for [HumHub](https://github.com/humhub/humhub)
to Docker Hub as `humhub/humhub`. Each branch in this repository corresponds to a branch in the
upstream HumHub source repository. The build workflow derives the HumHub source branch and the
Docker image tag directly from the current repository branch.

---

## Branch-to-Tag Mapping

### Nightly Builds

| Docker repo branch | HumHub source branch | Mutable tag | Immutable tag pattern | Notes |
|---|---|---|---|---|
| `main` | `master` | `stable-nightly` | `stable-nightly-YYYYMMDDHHMMSS-<sha7>` | permanent |
| `develop` | `develop` | `experimental-nightly` | `experimental-nightly-YYYYMMDDHHMMSS-<sha7>` | permanent |
| `v1.17` | `v1.17` | `1.17-nightly` | `1.17-nightly-YYYYMMDDHHMMSS-<sha7>` | example — see below |

`main` and `develop` are the two permanent branches. Additional version branches (e.g. `v1.17`)
are created on demand for older HumHub releases that still receive support and are removed once
that version reaches end-of-life.

Every build pushes **two tags**:

- **Mutable tag** — always points to the latest build of that branch (e.g. `stable-nightly`).
  Suitable for environments that want to stay current automatically.
- **Immutable tag** — uniquely identifies a specific build by timestamp and the upstream commit
  SHA. Suitable for pinning to a known-good state and for audit trails.

### Release Builds

The set of tags pushed depends on whether the `humhub/humhub` release originates from the `master` line
(built from docker `main`) or is a maintenance release of an older version (built from a
version branch such as `v1.17`).

**New release** (e.g. `v1.18.2`, built from docker `main`):

| Tag | Type | Description |
|---|---|---|
| `1.18.2` | Mutable | Exact version |
| `1.18` | Mutable | Always the latest patch of this minor version |
| `stable` | Mutable | Always the newest stable release overall |
| `1.18.2-YYYYMMDDHHMMSS-<sha7>` | Immutable | Pinnable, audit-safe build reference |

**Maintenance release** (e.g. `v1.17.5`, built from docker `v1.17`):

| Tag | Type | Description |
|---|---|---|
| `1.17.5` | Mutable | Exact version |
| `1.17` | Mutable | Always the latest patch of this minor version |
| `1.17.5-YYYYMMDDHHMMSS-<sha7>` | Immutable | Pinnable, audit-safe build reference |

The `stable` tag is intentionally absent from maintenance releases — it always reflects the
newest release from the `master` line only, consistent with how `stable-nightly` works.

**Why `latest` is not published**

`latest` is a conventional Docker tag with no technical special meaning beyond being the default
when no tag is specified. It is omitted from this project in favour of the more descriptive
`stable` tag, which communicates intent explicitly and is consistent with the nightly naming
convention (`stable-nightly`).

>Note that `stable` is a floating tag and will move across major versions, which may include
breaking changes.

---

## Nightly Build Workflow

Scheduled builds are controlled entirely from the `main` branch to work around the GitHub Actions
limitation that cron schedules only execute from the default branch.

```
.github/workflows/
  nightly-dispatcher.yml     ← main branch only; holds the cron schedule;
                                triggers docker-publish-nightly.yml on each target branch
  docker-publish-nightly.yml ← all branches; the actual build logic
  docker-cleanup.yml         ← main branch only; cleanup job
```

> **Why "main branch only"?**
> GitHub Actions cron schedules only ever execute from the repository's default branch (`main`),
> so `nightly-dispatcher.yml` and `docker-cleanup.yml` are never triggered on other branches
> even if the files are present there. They can safely remain in version branches.

### Dispatcher workflow (`nightly-dispatcher.yml`)

Runs on a schedule and triggers `docker-publish-nightly.yml` on each listed branch via
`workflow_dispatch` with a `ref` input. Adding or removing a branch from the dispatcher
matrix is the single control point for enabling or disabling nightly builds.

### Build workflow (`docker-publish-nightly.yml`)

Executed per branch. Performs the following steps:

1. Checks out the docker repo branch
2. Logs in to Docker Hub
3. Resolves the upstream HumHub commit SHA (`git ls-remote`) and generates the immutable tag
4. Builds the Docker image with `HUMHUB_GIT_BRANCH` set to the mapped upstream branch
5. Pushes both the mutable and the immutable tag to `humhub/humhub`

### Managing Nightly Builds

**Add a new version (e.g. `v1.18`)**

1. Create branch `v1.18` from `main`.
2. On `main`, add `v1.18` to the branch matrix in `nightly-dispatcher.yml`.

**Drop support for a version (e.g. `v1.17`)**

1. Remove `v1.17` from the branch matrix in `nightly-dispatcher.yml` on `main`.
2. Optionally archive or delete the `v1.17` branch.

**Temporarily pause all nightly builds**

Disable the `nightly-dispatcher.yml` workflow via the GitHub Actions UI:
**Actions** → select the workflow → **Disable workflow**.

**Trigger a manual build for a single branch**

Go to **Actions** → `Docker Publish Nightly Image CI` → **Run workflow** → select the target
branch.

---

## Release Build Workflow

Release builds are triggered whenever a new stable release is published in the upstream
[humhub/humhub](https://github.com/humhub/humhub) repository. The `develop` branch is out of
scope — only releases from the `master` line and supported maintenance versions are built.

### Trigger Flow

Builds are triggered by a `repository_dispatch` event sent from `humhub/humhub` immediately
when a release is published:

| Trigger | Source | Latency |
|---|---|---|
| `repository_dispatch` | `humhub/humhub` on `release: published` | Immediate |

### Workflow Architecture

```
humhub/humhub
  .github/workflows/
    notify-docker-release.yml  ← fires on "release: published";
                                  sends repository_dispatch to humhub/docker

humhub/docker
  .github/workflows/
    release-dispatcher.yml     ← main branch only; receives repository_dispatch;
                                  triggers docker-publish-release.yml
    docker-publish-release.yml ← all branches; reusable release build logic
```

A PAT with `actions: write` permission on `humhub/docker` must be stored as a secret
(e.g. `DOCKER_REPO_DISPATCH_TOKEN`) in `humhub/humhub`.

### Docker Repo Branch Selection

The docker repo branch and the `stable` tag decision are both derived directly from
`target_commitish` — the branch that was set as the release target in `humhub/humhub`:

| `target_commitish` | Docker repo branch | `stable` pushed? |
|---|---|---|
| `master` | `main` | yes |
| `v1.17` | `v1.17` | no |

`target_commitish` is included in the `repository_dispatch` payload automatically and is a
required input for manual `workflow_dispatch` runs.

### Managing Release Builds

**Add a new maintenance version (e.g. `v1.17`):**
Create the `v1.17` branch in `humhub/docker`. No changes to the release workflow are needed —
routing is driven by `target_commitish` from the release event.

**Drop support for a maintenance version (e.g. `v1.17`):**
Remove or archive the `v1.17` branch. No further release builds will be triggered for `v1.17.x`.

**Trigger a manual release build:**
Go to **Actions** → `Docker Publish Release CI` → **Run workflow**, select `main`, and provide
both required inputs:
- `release_tag` — the HumHub git tag (e.g. `v1.18.2`)
- `target_commitish` — the branch it was cut from in `humhub/humhub` (e.g. `master` or `v1.17`)

---

## Cleanup Process

A separate workflow (`docker-cleanup.yml`) runs daily at 04:33 UTC and removes stale images from
Docker Hub.

### What gets deleted

An image (digest) is considered **unused** when **all** of its tags match the immutable tag
pattern:

```
<branch>-YYYYMMDDHHMMSS-<sha7>
```

An image is considered **active** as long as it carries at least one mutable tag
(e.g. `stable-nightly`, `1.17-nightly`). Active images are never deleted.

In practice this means: when a new nightly build runs, the previous mutable tag is moved to the
new digest and the old digest becomes immutable-only. The cleanup job then removes it on its next
run.

### Dry-run mode

The cleanup script supports a `--dry-run` flag that prints what would be deleted without actually
deleting anything. To test locally:

```bash
bash image/files/dockerhub-cleanup-unused.sh \
  --namespace humhub \
  --repository humhub \
  --username <user> \
  --password <token> \
  --dry-run
```

---

## Docker Hub Tag Immutability

Docker Hub supports tag immutability rules defined by regex patterns. Configure these under
**Repository Settings → Tag immutability** in the `humhub/humhub` Docker Hub repository.

### Nightly immutable tags

Pattern — matches `stable-nightly-YYYYMMDDHHMMSS-<sha7>`, `experimental-nightly-…`, `1.17-nightly-…`:

```
^.+-nightly-[0-9]{14}-[0-9a-f]{7}$
```

Examples matched:
- `stable-nightly-20260416103300-a1b2c3d`
- `experimental-nightly-20260416103300-a1b2c3d`
- `1.17-nightly-20260416103300-a1b2c3d`

### Release immutable tags

Pattern — matches `1.18.2-YYYYMMDDHHMMSS-<sha7>`, `1.17.5-…`:

```
^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{14}-[0-9a-f]{7}$
```

Examples matched:
- `1.18.2-20260416103300-a1b2c3d`
- `1.17.5-20260416103300-a1b2c3d`

### Combined pattern

To cover all immutable tags (nightly and release) with a single rule:

```
^.+-[0-9]{14}-[0-9a-f]{7}$
```

---

## Appendix

- [Release Build Walkthrough](docker-release-walkthrough.md) — step-by-step trace of a release
  build from `humhub/humhub` release published to final Docker Hub state
