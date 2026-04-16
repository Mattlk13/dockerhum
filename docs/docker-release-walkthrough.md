# Appendix: Release Build Walkthrough

## Purpose

This document traces the complete automated flow triggered by a HumHub release, from the
moment the release is published in `humhub/humhub` to the final Docker Hub state. It is
intended as a reference for understanding and debugging the release build workflow.

## Assumptions

- HumHub release name: **`1.18.3`**, git tag: **`v1.18.3`**, target branch: **`master`**
- No `v1.18` branch exists in `humhub/docker` — this is a new release, not a maintenance release
- Secrets `DOCKER_REPO_DISPATCH_TOKEN` (in `humhub/humhub`) and `DOCKER_USER` / `DOCKER_PASSWORD`
  (in `humhub/docker`) are correctly configured
- Example timestamp: `20260416143022`, example SHA: `abc1234`

---

## Step 1: Release published in `humhub/humhub`

A maintainer publishes GitHub release named **`1.18.3`** with git tag **`v1.18.3`**, targeting
branch **`master`**. GitHub fires the `release: published` event.

---

## Step 2: `notify-docker-release.yml` fires in `humhub/humhub`

```
github.event.release.tag_name         = v1.18.3
github.event.release.target_commitish = master
```

Sends `repository_dispatch` to `humhub/docker`:

```json
{
  "event_type": "humhub-release",
  "client_payload": {
    "tag": "v1.18.3",
    "target_commitish": "master"
  }
}
```

---

## Step 3: `release-dispatcher.yml` receives the event on `humhub/docker` `main`

`resolve` job detects `github.event_name == "repository_dispatch"` and outputs:

```
release_tag      = v1.18.3
target_commitish = master
```

`build` job calls `docker-publish-release.yml` with both values.

---

## Step 4: `docker-publish-release.yml` resolve step

```
RELEASE_TAG      = v1.18.3
VERSION          = 1.18.3       # strip leading v
MINOR            = 1.18         # first two version components
target_commitish = master       # → DOCKER_BRANCH = main, PUSH_STABLE = true
```

---

## Step 5: Checkout

Checks out the `main` branch of `humhub/docker`.

---

## Step 6: Generate immutable tag

```
TIMESTAMP     = 20260416143022
GIT_SHA       = abc1234         # from refs/tags/v1.18.3 in humhub/humhub

immutable tag = 1.18.3-20260416143022-abc1234
```

---

## Step 7: Build

```bash
docker build . \
  --build-arg HUMHUB_GIT_BRANCH=v1.18.3 \
  --tag humhub/humhub:1.18.3 \
  --tag humhub/humhub:1.18 \
  --tag humhub/humhub:1.18.3-20260416143022-abc1234
```

---

## Step 8: Push

```bash
docker push humhub/humhub:1.18.3
docker push humhub/humhub:1.18
docker push humhub/humhub:1.18.3-20260416143022-abc1234
```

---

## Step 9: Push `stable` tag (`push_stable == true`)

```bash
docker tag humhub/humhub:1.18.3 humhub/humhub:stable
docker push humhub/humhub:stable
```

---

## Result on Docker Hub

| Tag | Points to |
|---|---|
| `stable` | `1.18.3` build |
| `1.18` | `1.18.3` build |
| `1.18.3` | `1.18.3` build |
| `1.18.3-20260416143022-abc1234` | `1.18.3` build (immutable) |
