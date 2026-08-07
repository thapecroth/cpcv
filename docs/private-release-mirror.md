# Private-first release mirroring

This project intentionally keeps two different repositories:

- The runtime archive can retain private operational history and remains
  private.
- The clean release candidate contains only reviewed source snapshots and also
  remains private until the owner explicitly changes its visibility.

These repositories must never be joined. A clean candidate is not a branch of
the runtime archive.

## Safe export procedure

1. Finish and test the source change in the runtime archive. Require a clean
   worktree and a reviewed commit.
2. Export only the committed source tree to a fresh staging directory using
   `git archive <reviewed-ref>`. This excludes `.git` history by design.
3. Review the staged file list and contents. Reject local configuration, image
   cache, logs, state, diagnostics, host names, usernames, proxy URLs, keys,
   tokens, screenshots, and test output that contains realistic secrets.
4. Confirm the clean candidate worktree is clean and that its `origin` is the
   intended private candidate remote.
5. Copy only the approved staged files into the candidate, then inspect the
   resulting file diff and run the full safe test suite in the candidate.
6. Create a new, generic candidate commit with a reviewed message. Do not reuse
   private commit messages or authorship metadata if it can identify a private
   machine or host.
7. Re-scan the candidate's complete reachable history and current tree before
   pushing it to its private remote. Tag or create a private release only after
   that review.

## Prohibited operations

Do not use any of the following to populate the candidate:

- `git merge`, `git rebase`, `git cherry-pick`, or `git pull` from the runtime
  archive.
- Pushing an archive ref directly to the candidate remote.
- Publishing a clone of the runtime archive, including a shallow clone.
- Copying a whole working directory with `.git`, local configuration, cache,
  logs, screenshots, or generated diagnostics.

Those actions can expose private commit history even when the final source tree
looks generic.

## Required pre-push checks

Run these checks against the clean candidate, not only the runtime archive:

- `git status --short` is empty before the controlled import and contains only
  reviewed source changes before committing.
- `git rev-list --all --count` and `git show-ref --head` contain only intended
  candidate commits and tags.
- `git diff --check` passes.
- The Windows network-free suite passes from the candidate, and any platform
  the candidate claims as supported has its corresponding network-free suite.
- A secret/history scan finds no personal host alias, local username/path,
  credentials, proxy URL, screenshots, logs, cache, or state.
- The candidate remote and its visibility are verified explicitly. No command
  in this process changes repository visibility.

Use an explicit, reviewed export script with a dry-run mode once this workflow
becomes routine. It should fail closed on an unclean worktree, unknown target
remote, unexpected file, or failed scan; it should never delete or overwrite a
repository wholesale.
